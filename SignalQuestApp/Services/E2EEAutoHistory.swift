import CryptoKit
import Foundation

/// Enveloppes de la clé d'historique du chiffrement automatique (E2EE-AUTO §5) :
/// vers un appareil (« C'est moi », rotation après un `REVOKE`), vers la HK
/// suivante (chaîne, §5.6) et vers une passkey (§5.5). Suit
/// `packages/core/e2ee-auto-history.ts` pour la lecture et le verdict face au
/// journal vérifié ; le chiffrement (ECDH P-256, HKDF-SHA256, AES-256-GCM), que
/// le cœur laisse aux apps, est fait ici avec CryptoKit. Vecteurs
/// `history-wrap-v1` et `passkey-wrap-v1`.
enum E2EEAutoHistory {
    static let historyWrapInfo = "signalquest-e2ee-auto-history-wrap-v1"
    static let passkeyWrapInfo = "signalquest-e2ee-auto-passkey-wrap-v1"
    /// `req` d'une enveloppe de la chaîne de HK (§5.6 étape 2).
    static let chainRequest = "chain"
    static let historyRecipientPrefix = "history:"
    static let credentialIdMaxBytes = 1_023
    static let maxKeyVersion: Int64 = 2_147_483_646

    enum Failure: Error, Equatable {
        case invalidField
        /// Le scalaire déchiffré ne redonne pas la HK annoncée (§2.2).
        case keyMismatch
    }

    // MARK: - Enveloppe d'historique (§5.4)

    struct Wrap: Equatable, Sendable {
        let senderDeviceId: String
        /// `R` : l'appareil destinataire, ou `history:<hk′PubB64>` pour la chaîne (§5.6).
        let recipient: String
        /// `kv` : version de la clé d'accord de R ; `1` pour la chaîne.
        let keyVersion: Int
        /// `req` : la demande « C'est moi », `rotation-<seq>` ou `chain`.
        let requestId: String
        /// `entryHash` de l'`ADD` (ou `ADD_PENDING`) de R ; pour la chaîne, de la `HISTORY_KEY` de HK′.
        let addHash: String
        /// La HK enveloppée.
        let hkPubB64: String
        let ephemeralB64: String
        let nonceB64: String
        /// Scalaire HK chiffré : 32 octets plus l'étiquette GCM de 16.
        let wrappedB64: String
        let signatureB64: String

        var jsonObject: [String: Any] {
            [
                "senderDeviceId": senderDeviceId, "recipient": recipient, "keyVersion": keyVersion,
                "requestId": requestId, "addHash": addHash, "hkPubB64": hkPubB64, "ephemeralB64": ephemeralB64,
                "nonceB64": nonceB64, "wrappedB64": wrappedB64, "signatureB64": signatureB64,
            ]
        }
    }

    private static let wrapKeys: Set<String> = [
        "senderDeviceId", "recipient", "keyVersion", "requestId", "addHash",
        "hkPubB64", "ephemeralB64", "nonceB64", "wrappedB64", "signatureB64",
    ]

    static func isHistoryRecipient(_ value: String) -> Bool {
        value.hasPrefix(historyRecipientPrefix) && E2EEAutoLog.isPublicKey(String(value.dropFirst(historyRecipientPrefix.count)))
    }

    /// `seq` d'un `req` de rotation (`rotation-<seq>`), sinon nil.
    static func rotationRequestSeq(_ requestId: String) -> Int64? {
        guard requestId.hasPrefix("rotation-") else { return nil }
        return E2EEAutoLog.decimal(String(requestId.dropFirst("rotation-".count)), in: 1...E2EEV2Canonical.maxSafeInteger)
    }

    /// Entier JSON (pas un booléen ni un flottant) dans `range`.
    private static func jsonInteger(_ value: Any?, in range: ClosedRange<Int64>) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        guard Double(integer) == number.doubleValue, range.contains(integer) else { return nil }
        return integer
    }

    private static func canonicalLength(_ value: Any?) -> Int? {
        (value as? String).flatMap(E2EEAutoLog.canonicalBase64)?.count
    }

    /// Lecture stricte de l'objet transmis : champs exacts, formats du §2.3, cohérence `R`/`req`/`kv`.
    static func parseWrap(_ object: [String: Any]) -> Wrap? {
        guard Set(object.keys) == wrapKeys,
              let senderDeviceId = object["senderDeviceId"] as? String, E2EEV2Canonical.isOpaque(senderDeviceId),
              let recipient = object["recipient"] as? String,
              let keyVersion = jsonInteger(object["keyVersion"], in: 1...maxKeyVersion),
              let requestId = object["requestId"] as? String,
              let addHash = object["addHash"] as? String, E2EEAutoLog.isDigest(addHash),
              let hkPubB64 = object["hkPubB64"] as? String, E2EEAutoLog.isPublicKey(hkPubB64),
              let ephemeralB64 = object["ephemeralB64"] as? String, E2EEAutoLog.isPublicKey(ephemeralB64),
              canonicalLength(object["nonceB64"]) == 12, let nonceB64 = object["nonceB64"] as? String,
              canonicalLength(object["wrappedB64"]) == 48, let wrappedB64 = object["wrappedB64"] as? String,
              let signatureB64 = object["signatureB64"] as? String else { return nil }
        if isHistoryRecipient(recipient) {
            guard requestId == chainRequest, keyVersion == 1, recipient != historyRecipientPrefix + hkPubB64 else { return nil }
        } else {
            // `rotation-` se lit d'abord comme une rotation, jamais comme un opaque A.1 (révision 6).
            guard E2EEV2Canonical.isOpaque(recipient),
                  rotationRequestSeq(requestId) != nil || (!requestId.hasPrefix("rotation-") && E2EEV2Canonical.isOpaque(requestId))
            else { return nil }
        }
        return Wrap(
            senderDeviceId: senderDeviceId, recipient: recipient, keyVersion: Int(keyVersion), requestId: requestId,
            addHash: addHash, hkPubB64: hkPubB64, ephemeralB64: ephemeralB64, nonceB64: nonceB64,
            wrappedB64: wrappedB64, signatureB64: signatureB64
        )
    }

    private static func context(userId: String, senderDeviceId: String, recipient: String, keyVersion: Int, requestId: String, addHash: String) -> [String] {
        [userId, senderDeviceId, recipient, String(keyVersion), requestId, addHash]
    }

    static func saltText(userId: String, senderDeviceId: String, recipient: String, keyVersion: Int, requestId: String, addHash: String) -> String {
        (["SQ-E2EE-AUTO-HISTORY-SALT", "1"] + context(
            userId: userId, senderDeviceId: senderDeviceId, recipient: recipient,
            keyVersion: keyVersion, requestId: requestId, addHash: addHash
        )).joined(separator: "\n")
    }

    static func aadText(
        userId: String, senderDeviceId: String, recipient: String, keyVersion: Int, requestId: String, addHash: String,
        hkPubB64: String, ephemeralB64: String
    ) -> String {
        (["SQ-E2EE-AUTO-HISTORY-WRAP", "1"] + context(
            userId: userId, senderDeviceId: senderDeviceId, recipient: recipient,
            keyVersion: keyVersion, requestId: requestId, addHash: addHash
        ) + [hkPubB64, ephemeralB64]).joined(separator: "\n")
    }

    static func signaturePayload(userId: String, wrap: Wrap) -> String {
        (["SQ-E2EE-AUTO-HISTORY-WRAP-SIGNATURE", "1"] + context(
            userId: userId, senderDeviceId: wrap.senderDeviceId, recipient: wrap.recipient,
            keyVersion: wrap.keyVersion, requestId: wrap.requestId, addHash: wrap.addHash
        ) + [wrap.hkPubB64, wrap.ephemeralB64, wrap.nonceB64, wrap.wrappedB64]).joined(separator: "\n")
    }

    /// HKDF-SHA256 : sel = SHA-256 de la chaîne de sel, 32 octets.
    static func derivedKey(inputKeyMaterial: Data, saltText: String, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: Data(SHA256.hash(data: Data(saltText.utf8))),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Le lecteur : un appareil (demande « C'est moi » ou rotation), ou le détenteur
    /// de HK′ qui remonte la chaîne. `keyVersions` : les versions de sa clé d'accord
    /// dont il garde la clé privée (la courante, et la précédente juste après une rotation, §4.3).
    enum Reader: Equatable, Sendable {
        case device(deviceId: String, keyVersions: [Int], openRequestIds: [String], heldHkPubB64: String?)
        case history(hkPubB64: String)
    }

    enum CheckError: String, Error, Sendable {
        case recipient = "RECIPIENT"
        case keyVersion = "KEY_VERSION"
        case addHash = "ADD_HASH"
        case request = "REQUEST"
        case rotation = "ROTATION"
        case historyKey = "HISTORY_KEY"
        case chain = "CHAIN"
        case sender = "SENDER"
        case senderTooRecent = "SENDER_TOO_RECENT"
        case signature = "SIGNATURE"
    }

    /// Les vérifications du §5.4 (et du §5.6 pour `rotation-<seq>` et `chain`), avant
    /// tout déchiffrement, face au journal vérifié du compte. Rend nil si l'enveloppe
    /// peut être ouverte.
    static func check(userId: String, wrap: Wrap, account: E2EEAutoLog.AccountState, reader: Reader) -> CheckError? {
        guard account.userId == userId else { return .recipient }
        let signingKeyB64: String
        switch reader {
        case let .history(hkPubB64):
            guard wrap.recipient == historyRecipientPrefix + hkPubB64,
                  let record = account.historyKeys.first(where: { $0.hkPubB64 == hkPubB64 }) else { return .recipient }
            guard wrap.addHash == record.entryHash else { return .addHash }
            guard let previous = record.previousHkPubB64, wrap.hkPubB64 == previous else { return .chain }
            guard wrap.senderDeviceId == record.signerDeviceId else { return .sender }
            guard record.createdAtMs - record.signerAddedAtMs >= E2EEAutoLog.signerMinAgeMs else { return .senderTooRecent }
            guard let signer = account.devices[record.signerDeviceId] else { return .sender }
            signingKeyB64 = signer.signingKeyB64

        case let .device(deviceId, keyVersions, openRequestIds, heldHkPubB64):
            guard wrap.recipient == deviceId, let device = account.devices[deviceId], device.status != .revoked else { return .recipient }
            guard wrap.addHash == device.addEntryHash else { return .addHash }
            guard keyVersions.contains(wrap.keyVersion), wrap.keyVersion <= device.keyVersion else { return .keyVersion }
            guard let current = account.historyKeyPubB64, wrap.hkPubB64 == current else { return .historyKey }
            if let rotationSeq = rotationRequestSeq(wrap.requestId) {
                // §5.6 étape 4 : HK′ suit un REVOKE vérifié et remplace la HK que le lecteur
                // détient. L'émetteur est tout appareil qui détient HK′, pas forcément le signataire.
                guard let record = account.historyKeys.first(where: { $0.seq == rotationSeq }),
                      record.hkPubB64 == wrap.hkPubB64, record.afterRevokeSeq != nil,
                      let heldHkPubB64, record.previousHkPubB64 == heldHkPubB64 else { return .rotation }
            } else if !openRequestIds.contains(wrap.requestId) {
                return .request
            }
            guard let sender = account.devices[wrap.senderDeviceId], sender.status == .active,
                  sender.deviceId != deviceId else { return .sender }
            signingKeyB64 = sender.signingKeyB64
        }
        return E2EEAutoLog.verify(
            publicKeyB64: signingKeyB64, payload: signaturePayload(userId: userId, wrap: wrap), signatureB64: wrap.signatureB64
        ) ? nil : .signature
    }

    /// Enveloppe HK vers la clé d'accord du destinataire (appareil, ou HK′ pour la
    /// chaîne). `sign` rend une signature DER à S bas de l'appareil émetteur, sans que
    /// sa clé quitte son magasin.
    static func seal(
        scalar: Data,
        userId: String,
        senderDeviceId: String,
        recipient: String,
        keyVersion: Int,
        requestId: String,
        addHash: String,
        recipientAgreementKey: P256.KeyAgreement.PublicKey,
        sign: (Data) throws -> Data,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
        nonce: Data = Data(AES.GCM.Nonce())
    ) throws -> Wrap {
        guard let hkPubB64 = E2EEAutoHistoryKey.publicKeyB64(scalar: scalar), nonce.count == 12 else { throw Failure.invalidField }
        let ephemeralB64 = ephemeral.publicKey.x963Representation.base64EncodedString()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientAgreementKey).withUnsafeBytes { Data($0) }
        let key = derivedKey(
            inputKeyMaterial: secret,
            saltText: saltText(userId: userId, senderDeviceId: senderDeviceId, recipient: recipient, keyVersion: keyVersion, requestId: requestId, addHash: addHash),
            info: historyWrapInfo
        )
        let aad = aadText(
            userId: userId, senderDeviceId: senderDeviceId, recipient: recipient, keyVersion: keyVersion,
            requestId: requestId, addHash: addHash, hkPubB64: hkPubB64, ephemeralB64: ephemeralB64
        )
        let sealed = try AES.GCM.seal(scalar, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: Data(aad.utf8))
        let unsigned = Wrap(
            senderDeviceId: senderDeviceId, recipient: recipient, keyVersion: keyVersion, requestId: requestId,
            addHash: addHash, hkPubB64: hkPubB64, ephemeralB64: ephemeralB64, nonceB64: nonce.base64EncodedString(),
            wrappedB64: (sealed.ciphertext + sealed.tag).base64EncodedString(), signatureB64: ""
        )
        let signature = try sign(Data(signaturePayload(userId: userId, wrap: unsigned).utf8))
        guard parseWrap(unsigned.jsonObject.merging(["signatureB64": signature.base64EncodedString()]) { $1 }) != nil else {
            throw Failure.invalidField
        }
        return Wrap(
            senderDeviceId: senderDeviceId, recipient: recipient, keyVersion: keyVersion, requestId: requestId,
            addHash: addHash, hkPubB64: hkPubB64, ephemeralB64: ephemeralB64, nonceB64: unsigned.nonceB64,
            wrappedB64: unsigned.wrappedB64, signatureB64: signature.base64EncodedString()
        )
    }

    /// Ouvre une enveloppe déjà acceptée par `check`, puis confirme que le scalaire
    /// reçu redonne la HK annoncée (§2.2).
    static func open(_ wrap: Wrap, userId: String, agreementKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        guard let ephemeralData = Data(base64Encoded: wrap.ephemeralB64),
              let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralData),
              let nonce = E2EEAutoLog.canonicalBase64(wrap.nonceB64), nonce.count == 12,
              let wrapped = E2EEAutoLog.canonicalBase64(wrap.wrappedB64), wrapped.count == 48 else { throw Failure.invalidField }
        let secret = try agreementKey.sharedSecretFromKeyAgreement(with: ephemeral).withUnsafeBytes { Data($0) }
        let key = derivedKey(
            inputKeyMaterial: secret,
            saltText: saltText(
                userId: userId, senderDeviceId: wrap.senderDeviceId, recipient: wrap.recipient,
                keyVersion: wrap.keyVersion, requestId: wrap.requestId, addHash: wrap.addHash
            ),
            info: historyWrapInfo
        )
        let aad = aadText(
            userId: userId, senderDeviceId: wrap.senderDeviceId, recipient: wrap.recipient, keyVersion: wrap.keyVersion,
            requestId: wrap.requestId, addHash: wrap.addHash, hkPubB64: wrap.hkPubB64, ephemeralB64: wrap.ephemeralB64
        )
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: wrapped.prefix(32), tag: wrapped.suffix(16))
        let scalar = try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        guard plaintextMatches(wrap, scalar: scalar) else { throw Failure.keyMismatch }
        return scalar
    }

    /// Après déchiffrement : le scalaire reçu est-il bien la HK annoncée (§2.2) ?
    static func plaintextMatches(_ wrap: Wrap, scalar: Data) -> Bool {
        E2EEAutoHistoryKey.publicKeyB64(scalar: scalar) == wrap.hkPubB64
    }

    // MARK: - Passkey (§5.5)

    struct PasskeyWrap: Equatable, Sendable {
        /// Entrée `eval.first` de l'extension WebAuthn `prf`.
        let prfSaltB64: String
        let nonceB64: String
        let wrappedB64: String
        let hkPubB64: String

        var jsonObject: [String: Any] {
            ["prfSaltB64": prfSaltB64, "nonceB64": nonceB64, "wrappedB64": wrappedB64, "hkPubB64": hkPubB64]
        }
    }

    /// `{credentialId}` : `b64url` sans bourrage, canonique, 1 à 1 023 octets une fois décodé.
    static func isPasskeyCredentialId(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
              }) else { return false }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let bytes = Data(base64Encoded: standard), (1...credentialIdMaxBytes).contains(bytes.count) else { return false }
        return bytes.base64URLEncodedNoPadding() == value
    }

    static func parsePasskeyWrap(_ object: [String: Any]) -> PasskeyWrap? {
        guard Set(object.keys) == ["prfSaltB64", "nonceB64", "wrappedB64", "hkPubB64"],
              canonicalLength(object["prfSaltB64"]) == 32, let prfSaltB64 = object["prfSaltB64"] as? String,
              canonicalLength(object["nonceB64"]) == 12, let nonceB64 = object["nonceB64"] as? String,
              canonicalLength(object["wrappedB64"]) == 48, let wrappedB64 = object["wrappedB64"] as? String,
              let hkPubB64 = object["hkPubB64"] as? String, E2EEAutoLog.isPublicKey(hkPubB64) else { return nil }
        return PasskeyWrap(prfSaltB64: prfSaltB64, nonceB64: nonceB64, wrappedB64: wrappedB64, hkPubB64: hkPubB64)
    }

    static func passkeySaltText(userId: String, credentialId: String) -> String {
        ["SQ-E2EE-AUTO-PASSKEY-SALT", "1", userId, credentialId].joined(separator: "\n")
    }

    static func passkeyAadText(userId: String, credentialId: String, hkPubB64: String) -> String {
        ["SQ-E2EE-AUTO-PASSKEY-WRAP", "1", userId, credentialId, hkPubB64].joined(separator: "\n")
    }

    /// Clé tirée de la sortie PRF (32 octets, `prf.results.first`), jamais d'un `hmac-secret` CTAP brut.
    static func passkeyKey(prfOutput: Data, userId: String, credentialId: String) -> SymmetricKey {
        derivedKey(inputKeyMaterial: prfOutput, saltText: passkeySaltText(userId: userId, credentialId: credentialId), info: passkeyWrapInfo)
    }

    static func sealPasskey(
        scalar: Data, prfOutput: Data, prfSalt: Data, userId: String, credentialId: String,
        nonce: Data = Data(AES.GCM.Nonce())
    ) throws -> PasskeyWrap {
        guard let hkPubB64 = E2EEAutoHistoryKey.publicKeyB64(scalar: scalar), prfOutput.count == 32, prfSalt.count == 32,
              nonce.count == 12, isPasskeyCredentialId(credentialId) else { throw Failure.invalidField }
        let sealed = try AES.GCM.seal(
            scalar, using: passkeyKey(prfOutput: prfOutput, userId: userId, credentialId: credentialId),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: Data(passkeyAadText(userId: userId, credentialId: credentialId, hkPubB64: hkPubB64).utf8)
        )
        return PasskeyWrap(
            prfSaltB64: prfSalt.base64EncodedString(), nonceB64: nonce.base64EncodedString(),
            wrappedB64: (sealed.ciphertext + sealed.tag).base64EncodedString(), hkPubB64: hkPubB64
        )
    }

    static func openPasskey(_ body: PasskeyWrap, prfOutput: Data, userId: String, credentialId: String) throws -> Data {
        guard prfOutput.count == 32, isPasskeyCredentialId(credentialId),
              let nonce = E2EEAutoLog.canonicalBase64(body.nonceB64), nonce.count == 12,
              let wrapped = E2EEAutoLog.canonicalBase64(body.wrappedB64), wrapped.count == 48 else { throw Failure.invalidField }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: wrapped.prefix(32), tag: wrapped.suffix(16))
        let scalar = try AES.GCM.open(
            box, using: passkeyKey(prfOutput: prfOutput, userId: userId, credentialId: credentialId),
            authenticating: Data(passkeyAadText(userId: userId, credentialId: credentialId, hkPubB64: body.hkPubB64).utf8)
        )
        guard E2EEAutoHistoryKey.publicKeyB64(scalar: scalar) == body.hkPubB64 else { throw Failure.keyMismatch }
        return scalar
    }
}
