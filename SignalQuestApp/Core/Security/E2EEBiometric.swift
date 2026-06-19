import Foundation
import Security
import LocalAuthentication

/// Coffre biométrique du mot de passe E2EE : stocke le mot de passe derrière
/// Face ID / Touch ID (SecAccessControl `.biometryCurrentSet`) pour déverrouiller
/// la messagerie chiffrée sans le retaper. 100 % local, aucune dépendance backend.
enum E2EEBiometric {
    static let enabledKey = "sq.security.e2eeBiometricEnabled"
    private static let service = "fr.signalquest.ios.e2ee.biometric"
    private static let account = "e2eePassword"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Vrai si un mot de passe est stocké (sans déclencher d'invite biométrique).
    static var hasStored: Bool {
        var query = baseQuery()
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecInteractionNotAllowed = l'item existe mais exige la biométrie.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Stocke (ou remplace) le mot de passe E2EE derrière la biométrie courante.
    @discardableResult
    static func store(password: String) -> Bool {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else { return false }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessControl as String] = access
        let ok = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if ok { isEnabled = true }
        return ok
    }

    /// Lit le mot de passe en déclenchant la biométrie avec un message clair.
    /// `nil` si l'utilisateur refuse, échoue, ou si rien n'est stocké.
    static func retrieve(reason: String) async -> String? {
        let context = LAContext()
        // Pré-authentifie avec notre message, puis réutilise le contexte pour lire
        // l'item sans second prompt.
        let authenticated = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                cont.resume(returning: success)
            }
        }
        guard authenticated else { return nil }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Efface le mot de passe stocké et désactive l'option (logout / wipe E2EE).
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        isEnabled = false
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
