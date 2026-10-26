import CryptoKit
import Foundation

/// Code de sécurité d'un contact (E2EE-AUTO), contrat v2, §7 : facultatif, comparé
/// de vive voix ou par QR. Il porte sur les clés de signature des appareils actifs
/// des deux comptes : un `ROTATE` (clé d'accord) ne le change pas, un appareil
/// ajouté ou révoqué le change. Suit `packages/core/e2ee-auto-safety-code.ts` ; le
/// vecteur `safety-code-v1` fait foi.
enum E2EEAutoSafetyCode {
    static let deviceFingerprintLabel = "SQ-E2EE-AUTO-DEVICE-FINGERPRINT"
    static let accountLabel = "SQ-E2EE-AUTO-SAFETY-ACCOUNT"
    static let qrPrefix = "SQSC1|"
    /// Chiffres par compte : 6 groupes de 5, tirés de 6 tranches de 5 octets du condensat.
    static let accountGroups = 6
    /// Empreinte courte d'un appareil (journal visible) : 4 groupes de 5 chiffres.
    static let shortFingerprintGroups = 4

    static func deviceFingerprintText(userId: String, deviceId: String, signingKeyB64: String) -> String {
        [deviceFingerprintLabel, "1", userId, deviceId, signingKeyB64].joined(separator: "\n")
    }

    static func deviceFingerprint(userId: String, deviceId: String, signingKeyB64: String) -> String {
        E2EEV2Canonical.sha256B64URL(Data(deviceFingerprintText(userId: userId, deviceId: deviceId, signingKeyB64: signingKeyB64).utf8))
    }

    /// Groupe `i` : octets `[5i, 5i + 5)`, entier big-endian (40 bits) modulo 100 000, sur 5 chiffres.
    private static func digitGroups(_ bytes: Data, count: Int) -> [String] {
        let bytes = Array(bytes)
        return (0..<count).map { index in
            let value = bytes[(index * 5)..<(index * 5 + 5)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let digits = String(value % 100_000)
            return String(repeating: "0", count: 5 - digits.count) + digits
        }
    }

    /// `<LABEL>\n1\n<userId>\n<n>` puis `\n<empreinte>` par appareil actif, triées par octets UTF-8.
    static func accountText(_ account: E2EEAutoLog.AccountState) -> String {
        let fingerprints = account.devices.values
            .filter { $0.status == .active }
            .map { deviceFingerprint(userId: account.userId, deviceId: $0.deviceId, signingKeyB64: $0.signingKeyB64) }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return ([accountLabel, "1", account.userId, String(fingerprints.count)] + fingerprints).joined(separator: "\n")
    }

    static func accountDigits(_ account: E2EEAutoLog.AccountState) -> String {
        digitGroups(Data(SHA256.hash(data: Data(accountText(account).utf8))), count: accountGroups).joined()
    }

    struct Code: Equatable, Sendable {
        let digits: String
        /// 12 groupes de 5 chiffres, pour l'affichage.
        let groups: [String]
        let qr: String
    }

    /// Code à 60 chiffres, le même des deux côtés : les 30 chiffres de chaque compte,
    /// comptes ordonnés par `userId` (octets UTF-8). nil pour deux fois le même compte.
    static func code(_ left: E2EEAutoLog.AccountState, _ right: E2EEAutoLog.AccountState) -> Code? {
        guard left.userId != right.userId else { return nil }
        let (first, second) = Array(left.userId.utf8).lexicographicallyPrecedes(Array(right.userId.utf8)) ? (left, right) : (right, left)
        let digits = accountDigits(first) + accountDigits(second)
        let groups = stride(from: 0, to: digits.count, by: 5).map { offset -> String in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return String(digits[start..<digits.index(start, offsetBy: 5)])
        }
        return Code(digits: digits, groups: groups, qr: qrPrefix + digits)
    }

    /// Lecture d'un QR scanné : `SQSC1|` puis exactement 60 chiffres ASCII, sinon nil.
    static func parseQR(_ text: String) -> String? {
        guard text.hasPrefix(qrPrefix) else { return nil }
        let digits = String(text.dropFirst(qrPrefix.count))
        guard digits.utf8.count == 60, digits.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        return digits
    }

    /// Empreinte courte d'un appareil : 4 groupes de 5 chiffres tirés des octets 0 à 19 de son empreinte.
    static func shortFingerprint(_ deviceFingerprint: String) -> [String]? {
        guard E2EEAutoLog.isDigest(deviceFingerprint) else { return nil }
        let standard = deviceFingerprint.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return nil }
        return digitGroups(bytes, count: shortFingerprintGroups)
    }
}

/// Codes de sécurité comparés et marqués vérifiés, par compte connecté et par
/// contact, sur cet appareil seulement. Le code change quand l'un des deux
/// comptes ajoute ou retire un appareil : l'écran le signale, rien n'est bloqué.
struct E2EEAutoSafetyCodeVerifications {
    var defaults: UserDefaults = .standard

    private func key(_ ownerNamespace: String) -> String { "e2ee-auto-safety-verified-v1:\(ownerNamespace)" }

    /// Les 60 chiffres vérifiés avec ce contact, s'il y en a.
    func verifiedDigits(peerUserId: String, ownerNamespace: String) -> String? {
        (defaults.dictionary(forKey: key(ownerNamespace)) as? [String: String])?[peerUserId]
    }

    func setVerified(_ digits: String?, peerUserId: String, ownerNamespace: String) {
        var all = (defaults.dictionary(forKey: key(ownerNamespace)) as? [String: String]) ?? [:]
        all[peerUserId] = digits
        if all.isEmpty {
            defaults.removeObject(forKey: key(ownerNamespace))
        } else {
            defaults.set(all, forKey: key(ownerNamespace))
        }
    }
}

extension E2EEAutoSafetyCode {
    enum AccountsRead: Equatable, Sendable {
        case verified(own: E2EEAutoLog.AccountState, peer: E2EEAutoLog.AccountState)
        /// Journal en alerte, compte tu ou refusé par le vérificateur.
        case refused
        /// Réseau ou réponse illisible : réessayer.
        case inconclusive
    }

    /// Les deux comptes, lus jusqu'à la tête vérifiée. Les appareils apparus
    /// depuis la lecture précédente partent comme avec l'annuaire (§4.2, §7).
    static func accounts(reader: E2EEAutoLogReader, ownUserId: String, peerUserId: String) async -> AccountsRead {
        do {
            if case .alert = try await reader.refreshLinks() { return .refused }
            guard case .success(let own)? = try await reader.account(ownUserId),
                  case .success(let peer)? = try await reader.account(peerUserId) else { return .refused }
            let added = await reader.takeAddedDevices()
            if !added.isEmpty { E2EEAutoDeviceEvents.post(ownerScopeId: reader.ownerScopeId, added: added) }
            return .verified(own: own, peer: peer)
        } catch {
            return .inconclusive
        }
    }
}
