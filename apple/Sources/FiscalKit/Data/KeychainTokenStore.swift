import Foundation
import Security

public enum TokenStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

public protocol DeviceTokenStoring: Sendable {
    func read() async throws -> String?
    func save(_ token: String) async throws
    func delete() async throws
}

/// Transition-only legacy device-token store. The passphrase model reads a still-valid device
/// token here to bridge the one-time `initialize` call that sets the access passphrase; after
/// that the app uses `AccessKeyStore` exclusively. Kept alongside the retained `device_tokens`
/// table and scheduled for removal in the next release. The pending-rotation machinery is gone.
public actor KeychainTokenStore: DeviceTokenStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?

    /// `accessGroup` pins items to an explicit keychain access group (iOS passes the
    /// team-qualified app group) so tokens stay addressable across signing/install variants.
    /// macOS passes nil — the implicit group is stable under Developer ID signing there.
    public init(
        service: String = "com.linotsai.fiscal.api",
        account: String = "device-token",
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
        guard status == errSecSuccess else { throw TokenStoreError.unexpectedStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.malformedData
        }
        return token
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.unexpectedStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw TokenStoreError.unexpectedStatus(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
