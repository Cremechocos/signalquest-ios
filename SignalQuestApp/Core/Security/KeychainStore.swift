import Foundation
import Security

protocol TokenStore: Sendable {
    func string(for key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func remove(_ key: String) throws
    /// Removes every item stored under this store's keychain service.
    func removeAll() throws
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

    init(service: String = "fr.signalquest.ios") {
        self.service = service
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

    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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

    func removeAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.unexpectedStatus(status)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
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

    func set(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}

