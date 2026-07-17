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
  }

  private var entries: [String: Entry] = [:]

  public init() {}

  public func data(for key: String, now: Date = .now) -> Data? {
    guard let entry = entries[key] else { return nil }
    guard entry.expiresAt > now else {
      entries.removeValue(forKey: key)
      return nil
    }
    return entry.data
  }

  public func store(
    _ data: Data,
    for key: String,
    ttl: TimeInterval = 30,
    now: Date = .now
  ) {
    guard ttl > 0 else { return }
    entries[key] = Entry(data: data, expiresAt: now.addingTimeInterval(min(ttl, 30)), storedAt: now)
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
