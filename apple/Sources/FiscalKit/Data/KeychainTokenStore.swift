import Foundation
import Security

public enum TokenStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

public actor KeychainTokenStore {
    private let service: String
    private let account: String

    public init(service: String = "com.linotsai.fiscal.api", account: String = "device-token") {
        self.service = service
        self.account = account
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
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TokenStoreError.unexpectedStatus(addStatus) }
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
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}
