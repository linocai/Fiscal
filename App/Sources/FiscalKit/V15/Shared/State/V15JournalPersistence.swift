import CryptoKit
import Foundation

/// Durable writes never share the optional read cache's eviction or error policy.
public struct V15JournalPersistence {
    public let read: () throws -> Data?
    public let write: (Data) throws -> Void

    public init(read: @escaping () throws -> Data?, write: @escaping (Data) throws -> Void) {
        self.read = read; self.write = write
    }

    public static func encrypted(directory: URL? = nil, scope: String, key: SymmetricKey? = nil) -> Self {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Fiscal/WriteJournal", directoryHint: .isDirectory)
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: "\(digest).bin")
        let keys = SnapshotKeyStore(service: "com.linotsai.fiscal.write-journal", account: digest)
        return .init(read: {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: key ?? keys.key())
        }, write: { data in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sealed = try AES.GCM.seal(data, using: key ?? keys.key())
            guard let bytes = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
            try bytes.write(to: file, options: .atomic)
            let checked = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: key ?? keys.key())
            guard checked == data else { throw CocoaError(.fileReadCorruptFile) }
        })
    }
}
