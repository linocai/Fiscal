import Foundation
import Security

public enum AccessKeyStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

public protocol AccessKeyStoring: Sendable {
    func read() async throws -> String?
    func save(_ accessKey: String) async throws
    func delete() async throws
}

/// Stores the opaque access key in the iCloud-synchronized keychain so a reinstall or a new
/// device recovers the connection automatically. `kSecAttrSynchronizable = true` opts the item
/// into iCloud Keychain (only the owner's Apple ID can sync it); accessibility is
/// `AfterFirstUnlock` — deliberately **not** `ThisDeviceOnly`, which cannot synchronize.
///
/// `accessGroup` pins items to an explicit keychain access group (iOS passes the team-qualified
/// group so the key stays addressable across signing/install variants); macOS passes nil.
public actor AccessKeyStore: AccessKeyStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "com.linotsai.fiscal.access",
        account: String = "access-key",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccessKeyStoreError.unexpectedStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AccessKeyStoreError.malformedData
        }
        return key
    }

    public func save(_ accessKey: String) throws {
        let data = Data(accessKey.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AccessKeyStoreError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw AccessKeyStoreError.unexpectedStatus(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccessKeyStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        Self.keychainQuery(service: service, account: account, accessGroup: accessGroup)
    }

    /// Exposed for tests to assert the item is iCloud-synchronizable and not device-bound.
    nonisolated static func keychainQuery(
        service: String, account: String, accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
