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

/// Stores the opaque access key in the keychain. iOS prefers an iCloud-synchronized item
/// (`kSecAttrSynchronizable = true`, accessibility `AfterFirstUnlock` — deliberately not
/// `ThisDeviceOnly`, which cannot synchronize) so a reinstall or a second device recovers the
/// connection automatically, and falls back to a local item when the synchronized write is
/// unavailable (iCloud Keychain off). macOS uses a local item only: a Developer ID app without
/// a provisioned keychain-access-groups entitlement cannot write synchronizable items at all —
/// the exact failure that stranded the v1.2.4 (17) migration — and the operator Mac has no
/// cross-device recovery need. Reads and deletes match both variants.
///
/// `accessGroup` pins items to an explicit keychain access group (iOS passes the team-qualified
/// group so the key stays addressable across signing/install variants); macOS passes nil.
public actor AccessKeyStore: AccessKeyStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let prefersSynchronizable: Bool

    #if os(iOS)
        public static let platformPrefersSynchronizable = true
    #else
        public static let platformPrefersSynchronizable = false
    #endif

    public init(
        service: String = "com.linotsai.fiscal.access",
        account: String = "access-key",
        accessGroup: String? = nil,
        prefersSynchronizable: Bool = AccessKeyStore.platformPrefersSynchronizable
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.prefersSynchronizable = prefersSynchronizable
    }

    public func read() throws -> String? {
        var query = matchAnyQuery
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
        let update = SecItemUpdate(
            matchAnyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw AccessKeyStoreError.unexpectedStatus(update)
        }
        var preferred = Self.writeQuery(
            service: service, account: account, accessGroup: accessGroup,
            synchronizable: prefersSynchronizable)
        preferred[kSecValueData as String] = data
        var added = SecItemAdd(preferred as CFDictionary, nil)
        if added != errSecSuccess, prefersSynchronizable {
            // iCloud Keychain unavailable — a local key still connects this device; a later
            // reinstall falls back to re-entering the memorized passphrase.
            var local = Self.writeQuery(
                service: service, account: account, accessGroup: accessGroup,
                synchronizable: false)
            local[kSecValueData as String] = data
            added = SecItemAdd(local as CFDictionary, nil)
        }
        guard added == errSecSuccess else {
            throw AccessKeyStoreError.unexpectedStatus(added)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(matchAnyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccessKeyStoreError.unexpectedStatus(status)
        }
    }

    /// Matches the stored key regardless of which variant a previous build wrote.
    private var matchAnyQuery: [String: Any] {
        Self.matchQuery(service: service, account: account, accessGroup: accessGroup)
    }

    /// Exposed for tests: lookup spans both synchronizable and local variants.
    nonisolated static func matchQuery(
        service: String, account: String, accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Exposed for tests: the write shape for one concrete variant.
    nonisolated static func writeQuery(
        service: String, account: String, accessGroup: String?, synchronizable: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
