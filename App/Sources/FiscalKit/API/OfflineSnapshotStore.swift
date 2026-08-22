import CryptoKit
import Foundation
import Security

public struct OfflineSnapshotStatus: Sendable, Equatable {
  public let storedAt: Date
  public init(storedAt: Date) { self.storedAt = storedAt }
}

/// Encrypted, persistent read-only fallback for a completed GET. It has no request queue and
/// is deliberately separate from `HTTPResponseCache`: the VPS remains the only write authority.
public actor OfflineSnapshotStore {
  public static let shared = OfflineSnapshotStore()

  private struct Envelope: Codable {
    let nonce: Data
    let ciphertext: Data
  }

  private struct Snapshot: Codable {
    let storedAt: Date
    let data: Data
  }

  private struct Payload: Codable {
    var values: [String: Snapshot]
  }

  private let fileManager: FileManager
  private let directory: URL
  private let keyStore: SnapshotKeyStore
  private let maxEntries: Int
  private let maxPayloadBytes: Int
  private let maxSingleResponseBytes: Int

  public init(
    fileManager: FileManager = .default,
    directory: URL? = nil,
    keyStore: SnapshotKeyStore = .init(),
    maxEntries: Int = 128,
    maxPayloadBytes: Int = 16 * 1024 * 1024,
    maxSingleResponseBytes: Int = 1024 * 1024
  ) {
    self.fileManager = fileManager
    self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory,
      in: .userDomainMask)[0].appending(path: "Fiscal/OfflineSnapshots", directoryHint: .isDirectory)
    self.keyStore = keyStore
    self.maxEntries = maxEntries; self.maxPayloadBytes = maxPayloadBytes
    self.maxSingleResponseBytes = maxSingleResponseBytes
  }

  public func store(_ data: Data, for key: String, now: Date = .now) {
    guard data.count <= maxSingleResponseBytes else { return }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      var payload = try loadPayload()
      payload.values[key] = .init(storedAt: now, data: data)
      while payload.values.count > maxEntries || payload.values.values.reduce(0, { $0 + $1.data.count }) > maxPayloadBytes {
        guard let oldest = payload.values.min(by: { $0.value.storedAt < $1.value.storedAt })?.key else { break }
        payload.values.removeValue(forKey: oldest)
      }
      try write(payload)
    } catch {
      // A read response must remain usable even when the optional offline cache cannot persist.
    }
  }

  public func data(for key: String) -> (data: Data, status: OfflineSnapshotStatus)? {
    do {
      let snapshot = try loadPayload().values[key]
      guard let snapshot else { return nil }
      return (snapshot.data, .init(storedAt: snapshot.storedAt))
    } catch {
      return nil
    }
  }

  public func removeAll() {
    try? fileManager.removeItem(at: fileURL)
  }

  public func remove(_ key: String) {
    do {
      var payload = try loadPayload()
      payload.values.removeValue(forKey: key)
      try write(payload)
    } catch {}
  }

  public func entryCount() -> Int { (try? loadPayload().values.count) ?? 0 }

  private var fileURL: URL { directory.appending(path: "read-only-snapshots.bin") }

  private func loadPayload() throws -> Payload {
    guard fileManager.fileExists(atPath: fileURL.path()) else { return .init(values: [:]) }
    let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: envelope.nonce), ciphertext: envelope.ciphertext.dropLast(16),
      tag: envelope.ciphertext.suffix(16))
    return try JSONDecoder().decode(Payload.self, from: AES.GCM.open(box, using: keyStore.key()))
  }

  private func write(_ payload: Payload) throws {
    let sealed = try AES.GCM.seal(try JSONEncoder().encode(payload), using: try keyStore.key())
    let envelope = Envelope(nonce: Data(sealed.nonce), ciphertext: sealed.ciphertext + sealed.tag)
    try JSONEncoder().encode(envelope).write(to: fileURL, options: .atomic)
  }
}

public final class SnapshotKeyStore: @unchecked Sendable {
  private let service: String
  private let account: String

  public init(service: String = "com.linotsai.fiscal.offline-snapshot", account: String = "aes-256-key") {
    self.service = service; self.account = account
  }

  func key() throws -> SymmetricKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data, data.count == 32 { return SymmetricKey(data: data) }
    guard status == errSecItemNotFound else { throw AccessKeyStoreError.unexpectedStatus(status) }
    var data = Data(count: 32)
    let randomStatus = data.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    guard randomStatus == errSecSuccess else { throw AccessKeyStoreError.unexpectedStatus(randomStatus) }
    var add = query
    add.removeValue(forKey: kSecReturnData as String)
    add.removeValue(forKey: kSecMatchLimit as String)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw AccessKeyStoreError.unexpectedStatus(added) }
    return SymmetricKey(data: data)
  }
}
