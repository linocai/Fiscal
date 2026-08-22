import Foundation
import Observation

public struct DataRevisionReceipt: Sendable, Equatable {
  public let revision: Int64
  public let scopes: Set<String>
  public init(revision: Int64, scopes: Set<String>) { self.revision = revision; self.scopes = scopes }
}

public struct DataRevisionResponse: Codable, Sendable, Equatable {
  public let revision: Int64
  public init(revision: Int64) { self.revision = revision }
}

public enum FormalSubmissionGate {
  public static func canSubmit(offlineSnapshotAt: Date?) -> Bool { offlineSnapshotAt == nil }
}

/// Server receipts are the only cross-screen invalidation source. Older servers
/// and clients simply omit this additive contract.
@MainActor @Observable
public final class DataRevisionStore {
  public private(set) var latest: DataRevisionReceipt?
  public private(set) var offlineSnapshotAt: Date?
  private let defaults: UserDefaults?
  private let storageKey: String

  public init(defaults: UserDefaults? = .standard, storageKey: String = "fiscal.data-revision") {
    self.defaults = defaults; self.storageKey = storageKey
    if let stored = defaults?.object(forKey: storageKey) as? NSNumber {
      latest = .init(revision: stored.int64Value, scopes: [])
    }
  }

  public func accept(_ receipt: DataRevisionReceipt) {
    guard receipt.revision > (latest?.revision ?? -1) else { return }
    latest = receipt
    defaults?.set(receipt.revision, forKey: storageKey)
  }

  public var currentRevision: Int64? { latest?.revision }

  /// The server poll is authoritative unless a local receipt advanced after this particular poll
  /// started. That preserves an in-flight mutation's newer receipt while allowing an archive
  /// restore/new database epoch to reset a lower revision even in the same app process.
  public func observeServer(revision: Int64, pollBaseline: Int64?) {
    let current = latest?.revision
    if let pollBaseline, current != pollBaseline, revision <= (current ?? -1) { return }
    if revision != current {
      latest = .init(revision: revision, scopes: [])
      defaults?.set(revision, forKey: storageKey)
    }
    offlineSnapshotAt = nil
  }

  public func markOfflineSnapshot(at date: Date) {
    offlineSnapshotAt = date
  }

  public func markOnline() { offlineSnapshotAt = nil }

}
