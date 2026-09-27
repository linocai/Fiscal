import Foundation
import Security
import Testing

@testable import FiscalKit

@Suite("FiscalKit P19 access passphrase")
struct P19AccessPassphraseTests {
    @Test("iOS writes prefer the iCloud-synchronizable variant, never device-bound accessibility")
    func synchronizableWriteShape() {
        let query = AccessKeyStore.writeQuery(
            service: "com.linotsai.fiscal.access", account: "access-key",
            accessGroup: "HX73DFL88G.com.linotsai.fiscal", synchronizable: true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
        #expect((query[kSecAttrService as String] as? String) == "com.linotsai.fiscal.access")
        #expect((query[kSecAttrAccount as String] as? String) == "access-key")
        #expect(
            (query[kSecAttrAccessGroup as String] as? String) == "HX73DFL88G.com.linotsai.fiscal")
        let accessible = query[kSecAttrAccessible as String]
        #expect((accessible as! CFString) == kSecAttrAccessibleAfterFirstUnlock)
        // Device-bound accessibility cannot synchronize; make sure we did not pick it.
        #expect((accessible as! CFString) != kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    @Test("macOS writes are local: Developer ID without provisioned entitlements cannot sync")
    func macWriteShapeIsLocal() {
        let query = AccessKeyStore.writeQuery(
            service: "com.linotsai.fiscal.access", account: "access-key",
            accessGroup: nil, synchronizable: false)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(AccessKeyStore.platformPrefersSynchronizable == false)
    }

    @Test("Reads and deletes match both variants so older builds' items are still found")
    func lookupSpansBothVariants() {
        let query = AccessKeyStore.matchQuery(
            service: "com.linotsai.fiscal.access", account: "access-key", accessGroup: nil)
        #expect((query[kSecAttrSynchronizable as String] as! CFString) == kSecAttrSynchronizableAny)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

}
