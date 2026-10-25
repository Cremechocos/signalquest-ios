import Foundation

/// Appareils des membres tirés du journal vérifié (E2EE-AUTO §4.2), et de rien
/// d'autre, sous la forme que lisent déjà la création, l'envoi, la réception,
/// les époques et les appels : `E2EEV2CertifiedDeviceSet`. Un appareil actif y
/// porte sa clé d'accord du dernier `ROTATE` et l'empreinte D.0 des manifestes.
enum E2EEAutoDeviceDirectory {
    /// Ce que sait faire toute app au-dessus de la version minimale (§7) : sans
    /// document publié, l'intersection d'une conversation se réduit à ce que
    /// cette app-ci sait faire.
    static func capabilities(userId: String, device: E2EEAutoLog.DeviceState) -> E2EEV2CapabilitiesDocument {
        E2EEV2CapabilitiesDocument(
            userId: userId, deviceId: device.deviceId, sequence: device.keyVersion,
            issuedAtMs: device.activatedAtMs ?? device.addedAtMs,
            envelopeVersions: E2EEV2CapabilitiesPublicationStore.envelopeVersions, payloadVersions: ["2"],
            kinds: E2EEV2CapabilitiesPublicationStore.kinds, features: E2EEV2CapabilitiesPublicationStore.features
        )
    }

    static func certifiedDevice(userId: String, device: E2EEAutoLog.DeviceState) -> E2EEV2CertifiedDevice {
        E2EEV2CertifiedDevice(
            userId: userId, deviceId: device.deviceId, keyVersion: device.keyVersion,
            platform: device.platform.rawValue, identityKeyB64: device.identityKeyB64,
            signingKeyB64: device.signingKeyB64, fingerprint: E2EEAutoEpoch.recipientFingerprint(device),
            capabilities: capabilities(userId: userId, device: device), verifiedByLog: true
        )
    }

    /// `accounts` : le résultat de `E2EEAutoLogReader.account` par compte lu ;
    /// nil = non servi (404). Un journal refusé retire ce membre sans faire
    /// échouer les autres, comme un paquet de confiance refusé ; un compte pas
    /// encore passé en auto n'a aucun appareil et n'empêche rien (§7).
    static func deviceSet(
        accounts: [String: Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>?]
    ) -> E2EEV2CertifiedDeviceSet {
        var devices: [String: [E2EEV2CertifiedDevice]] = [:]
        var refusals: [String: E2EEV2IdentityVerification.Failure] = [:]
        var logSeqs: [String: Int64] = [:]
        for (userId, read) in accounts {
            switch read {
            case .success(let account)?:
                devices[userId] = account.activeDevices.map { certifiedDevice(userId: userId, device: $0) }
                logSeqs[userId] = account.lastSeq
            case .failure?:
                refusals[userId] = .invalidDeviceList
            case nil:
                refusals[userId] = .notFound
            }
        }
        // Un destinataire est un couple (userId, deviceId) : le même deviceId sous
        // deux comptes est admis (§7.1, révision 4), sans filtre d'ambiguïté.
        return E2EEV2CertifiedDeviceSet(devicesByUser: devices, refusals: refusals, logSeqs: logSeqs)
    }
}
