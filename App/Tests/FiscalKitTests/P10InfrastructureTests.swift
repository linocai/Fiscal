import Foundation
import Testing
@testable import FiscalKit

@Suite("FiscalKit P10 infrastructure")
struct P10InfrastructureTests {
  @Test("Recording preferences validate defaults and persist only local values") @MainActor
  func recordingPreferencesValidation() {
    let suite = "fiscal-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = RecordingPreferences(defaults: defaults)
    let active = account(kind: .debit)
    let archived = account(kind: .cash, archivedAt: Date())

    preferences.defaultKind = .income
    preferences.stayAfterSave = true
    preferences.setDefaultAccount(active.id)
    #expect(preferences.validatedDefaultAccount(in: [active, archived]) == active.id)

    let restored = RecordingPreferences(defaults: defaults)
    #expect(restored.defaultKind == .income)
    #expect(restored.stayAfterSave)
    #expect(restored.defaultAccountID == active.id)

    restored.setDefaultAccount(archived.id)
    #expect(restored.validatedDefaultAccount(in: [active, archived]) == nil)
    #expect(restored.defaultAccountID == nil)
  }

  @Test("Continuous recording resets content and rotates idempotency") @MainActor
  func continuousRecordingReset() {
    let active = account(kind: .debit)
    let model = TransactionEditorModel()
    model.changeKind(.income)
    model.draft.accountID = active.id
    model.draft.categoryID = UUID()
    model.draft.title = "工资"
    model.draft.note = "七月"
    model.amountText = "100"
    let previousKey = model.idempotencyKey

    model.resetForNextEntry(validAccounts: [active])

    #expect(model.draft.kind == .income)
    #expect(model.draft.accountID == active.id)
    #expect(model.draft.categoryID == nil)
    #expect(model.draft.title.isEmpty)
    #expect(model.draft.note.isEmpty)
    #expect(model.amountText.isEmpty)
    #expect(model.idempotencyKey != previousKey)
  }

  @Test("Memory response cache expires, reports real bytes, and clears")
  func responseCacheLifecycle() async {
    let cache = HTTPResponseCache()
    let start = Date(timeIntervalSince1970: 1_000)
    let data = Data("fiscal".utf8)

    await cache.store(data, for: "ledger", ttl: 30, now: start)
    #expect(await cache.data(for: "ledger", now: start.addingTimeInterval(29)) == data)
    #expect(
      await cache.snapshot(now: start.addingTimeInterval(29))
        == HTTPResponseCacheSnapshot(entryCount: 1, byteCount: 6, lastUpdatedAt: start))
    #expect(await cache.data(for: "ledger", now: start.addingTimeInterval(30)) == nil)

    await cache.store(data, for: "ledger", now: start)
    await cache.removeAll()
    #expect(await cache.snapshot(now: start).entryCount == 0)
  }

  @Test("Response cache TTL is capped at thirty seconds")
  func responseCacheCapsTTL() async {
    let cache = HTTPResponseCache()
    let start = Date(timeIntervalSince1970: 2_000)
    await cache.store(Data([1]), for: "overview", ttl: 300, now: start)
    #expect(await cache.data(for: "overview", now: start.addingTimeInterval(31)) == nil)
  }

  @Test("CSV export receives the normalized current filters without paging") @MainActor
  func csvExportUsesCurrentFilters() async throws {
    let repository = CSVExportCaptureRepository()
    let model = TransactionsModel(repository: repository)
    model.search = "  午餐  "
    model.classification = .uncategorized
    model.source = "ocr"
    model.amountMinMinor = 1_000
    model.amountMaxMinor = 9_900

    let data = try await model.exportCSV()
    let query = try #require(await repository.exportedQuery())

    #expect(data == Data("csv".utf8))
    #expect(query.cursor == nil)
    #expect(query.search == "午餐")
    #expect(query.classification == .uncategorized)
    #expect(query.source == "ocr")
    #expect(query.amountMinMinor == 1_000)
    #expect(query.amountMaxMinor == 9_900)
  }

  private func account(kind: AccountKind, archivedAt: Date? = nil) -> AccountDTO {
    let now = Date(timeIntervalSince1970: 1_000)
    return AccountDTO(
      id: UUID(), name: "默认账户", kind: kind, institution: nil, lastFour: nil,
      openingBalanceMinor: 0, currentBalanceMinor: 0, openingBalanceAsOfDate: nil,
      openingDueDate: nil, creditLimitMinor: kind == .credit ? 100_000 : nil,
      statementDay: kind == .credit ? 10 : nil, dueDay: kind == .credit ? 22 : nil,
      sortOrder: 0, archivedAt: archivedAt, usageCount: 0, version: 1,
      createdAt: now, updatedAt: now)
  }
}

private actor CSVExportCaptureRepository: TransactionRepository {
  private var captured: TransactionQuery?

  func exportedQuery() -> TransactionQuery? { captured }
  func exportCSV(_ query: TransactionQuery) async throws -> Data {
    captured = query
    return Data("csv".utf8)
  }
  func list(_ query: TransactionQuery) async throws -> TransactionPage { throw TestError.unused }
  func get(id: UUID) async throws -> TransactionDTO { throw TestError.unused }
  func create(_ draft: TransactionDraft, idempotencyKey: UUID) async throws -> TransactionDTO {
    throw TestError.unused
  }
  func update(id: UUID, version: Int, draft: TransactionDraft) async throws -> TransactionDTO {
    throw TestError.unused
  }
  func void(_ transaction: TransactionDTO) async throws -> TransactionDTO { throw TestError.unused }
  func restore(_ transaction: TransactionDTO) async throws -> TransactionDTO { throw TestError.unused }

  private enum TestError: Error { case unused }
}
