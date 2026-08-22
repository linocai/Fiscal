import Foundation

public struct PendingTransactionDraft: Codable, Sendable, Equatable {
  public let draft: TransactionDraft
  public let amountText: String
  public let idempotencyKey: UUID
  public let savedAt: Date

  public init(draft: TransactionDraft, amountText: String, idempotencyKey: UUID, savedAt: Date = .now) {
    self.draft = draft; self.amountText = amountText; self.idempotencyKey = idempotencyKey; self.savedAt = savedAt
  }
}

/// Explicit local-only state for the primary transaction editor. It shares the offline snapshot
/// AEAD/Keychain key, is never exposed as a network request, and is removed only after the user
/// receives a successful create response.
public actor TransactionLocalDraftStore {
  public static let shared = TransactionLocalDraftStore()
  private let encryptedStore: OfflineSnapshotStore
  private let key = "p22.unsubmitted-transaction-draft"

  public init(encryptedStore: OfflineSnapshotStore = .shared) { self.encryptedStore = encryptedStore }

  public func save(_ value: PendingTransactionDraft) async {
    if let data = try? JSONEncoder().encode(value) { await encryptedStore.store(data, for: key) }
  }

  public func load() async -> PendingTransactionDraft? {
    guard let value = await encryptedStore.data(for: key) else { return nil }
    return try? JSONDecoder().decode(PendingTransactionDraft.self, from: value.data)
  }

  public func remove() async { await encryptedStore.remove(key) }
}
