import Foundation

public struct HTTPResponseCacheSnapshot: Sendable, Equatable {
  public let entryCount: Int
  public let byteCount: Int
  public let lastUpdatedAt: Date?

  public init(entryCount: Int, byteCount: Int, lastUpdatedAt: Date?) {
    self.entryCount = entryCount
    self.byteCount = byteCount
    self.lastUpdatedAt = lastUpdatedAt
  }
}

/// A deliberately short-lived, memory-only cache. The VPS remains authoritative and mutations
/// invalidate every entry before the next read can be served.
public actor HTTPResponseCache {
  public static let shared = HTTPResponseCache()

  private struct Entry: Sendable {
    let data: Data
    let expiresAt: Date
    let storedAt: Date
    var access: UInt64
  }

  private var entries: [String: Entry] = [:]

  private var access: UInt64 = 0
  private let maxEntries: Int
  private let maxPayloadBytes: Int
  private let maxSingleResponseBytes: Int
  public init(maxEntries: Int = 128, maxPayloadBytes: Int = 16 * 1024 * 1024, maxSingleResponseBytes: Int = 1024 * 1024) {
    self.maxEntries = max(0, maxEntries); self.maxPayloadBytes = max(0, maxPayloadBytes); self.maxSingleResponseBytes = max(0, maxSingleResponseBytes)
  }
  private func prune(_ now: Date) { entries = entries.filter { $0.value.expiresAt > now } }

  public func data(for key: String, now: Date = .now) -> Data? {
    prune(now)
    guard let entry = entries[key] else { return nil }
    guard entry.expiresAt > now else {
      entries.removeValue(forKey: key)
      return nil
    }
    access &+= 1; entries[key]?.access = access
    return entry.data
  }

  public func store(
    _ data: Data,
    for key: String,
    ttl: TimeInterval = 30,
    now: Date = .now
  ) {
    prune(now)
    entries.removeValue(forKey: key)
    guard ttl > 0, data.count <= maxSingleResponseBytes, data.count <= maxPayloadBytes, maxEntries > 0 else { return }
    access &+= 1
    entries[key] = Entry(data: data, expiresAt: now.addingTimeInterval(min(ttl, 30)), storedAt: now, access: access)
    while entries.count > maxEntries || entries.values.reduce(0, { $0 + $1.data.count }) > maxPayloadBytes {
      guard let victim = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
      entries.removeValue(forKey: victim)
    }
  }

  public func remove(_ key: String) {
    entries.removeValue(forKey: key)
  }

  public func removeAll() {
    entries.removeAll(keepingCapacity: false)
  }

  public func snapshot(now: Date = .now) -> HTTPResponseCacheSnapshot {
    entries = entries.filter { $0.value.expiresAt > now }
    return HTTPResponseCacheSnapshot(
      entryCount: entries.count,
      byteCount: entries.values.reduce(0) { $0 + $1.data.count },
      lastUpdatedAt: entries.values.map(\.storedAt).max())
  }
}
