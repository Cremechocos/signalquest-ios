import Foundation
import Security

/// Niveau d'accessibilité Keychain par type de secret (SEC-KEYCHAIN-01).
enum KeychainAccessibility {
    /// Lisible dès le 1er déverrouillage après démarrage, MÊME écran verrouillé —
    /// requis pour le token d'auth (refresh en arrière-plan, réponse à un appel
    /// VoIP sur écran verrouillé).
    case afterFirstUnlock
    /// Lisible UNIQUEMENT quand l'appareil est activement déverrouillé — pour les
    /// secrets E2EE (clé privée, clés de conversation), jamais accédés en
    /// arrière-plan (déchiffrement strictement en foreground).
    case whenUnlocked

    var cfValue: CFString {
        switch self {
        case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

protocol TokenStore: Sendable {
    func string(for key: String) throws -> String?
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws
    func remove(_ key: String) throws
    func keys(withPrefix prefix: String) throws -> [String]
    /// Removes every item stored under this store's keychain service.
    func removeAll() throws
}

extension TokenStore {
    /// Défaut historique : `afterFirstUnlock` (token d'auth). Les secrets E2EE
    /// doivent explicitement passer `.whenUnlocked`.
    func set(_ value: String, for key: String) throws {
        try set(value, for: key, accessibility: .afterFirstUnlock)
    }

    /// Compatibility for specialized stores that do not expose enumeration.
    /// Security-sensitive bulk purges must use a store implementation that
    /// overrides this method and can prove its exact scope.
    func keys(withPrefix prefix: String) throws -> [String] { [] }
}

enum KeychainError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain status \(status)"
        case .invalidData:
            return "Invalid keychain data"
        }
    }
}

final class KeychainStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?

    init(service: String = "fr.signalquest.ios", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func string(for key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.cfValue
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw KeychainError.unexpectedStatus(status) }
        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.unexpectedStatus(status)
    }

    func keys(withPrefix prefix: String) throws -> [String] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        let values: [[String: Any]]
        if let many = item as? [[String: Any]] {
            values = many
        } else if let one = item as? [String: Any] {
            values = [one]
        } else {
            throw KeychainError.invalidData
        }
        return values.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    func removeAll() throws {
        let query = serviceQuery()
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.unexpectedStatus(status)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = key
        return query
    }

    private func serviceQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    func keys(withPrefix prefix: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}
