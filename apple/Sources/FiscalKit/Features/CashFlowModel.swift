import Foundation
import Observation

public enum FutureCashFlowPhase: Sendable, Equatable { case idle, loading, loaded, empty, failed }

@MainActor
@Observable
public final class FutureCashFlowModel {
  public private(set) var active: FutureCashFlowActive?
  public private(set) var history: FutureCashFlowHistory?
  public private(set) var phase: FutureCashFlowPhase = .idle
  public private(set) var message: String?
  public private(set) var isMutating = false
  public var showingHistory = false
  public private(set) var historyMonth: String
  private let repository: any FutureCashFlowRepository

  public init(repository: any FutureCashFlowRepository, now: Date = Date()) {
    self.repository = repository
    historyMonth = Self.monthFormatter.string(from: now)
  }

  public func load() async {
    phase = active == nil ? .loading : .loaded; message = nil
    do {
      active = try await repository.active(accountID: nil)
      phase = active?.items.isEmpty == true ? .empty : .loaded
    } catch is CancellationError {} catch { apply(error) }
  }

  public func loadHistory() async {
    do { history = try await repository.history(month: historyMonth) }
    catch is CancellationError {} catch { apply(error) }
  }

  public func moveHistoryMonth(_ offset: Int) async {
    guard let anchor = Self.monthParser.date(from: "\(historyMonth)-01"),
      let shifted = Self.calendar.date(byAdding: .month, value: offset, to: anchor)
    else { return }
    historyMonth = Self.monthFormatter.string(from: shifted)
    await loadHistory()
  }

  public func create(_ draft: FutureCashFlowDraft) async -> Bool {
    await mutate { _ = try await self.repository.create(draft, idempotencyKey: UUID()) }
  }

  public func update(
    _ item: FutureCashFlowItem, draft: FutureCashFlowDraft,
    scope: FutureCashFlowMutationScope
  ) async -> Bool {
    guard let id = item.manualItemID else { return false }
    return await mutate {
      _ = try await self.repository.update(
        id: id,
        request: FutureCashFlowReplace(
          draft: draft, expectedVersion: item.version, scope: scope))
    }
  }

  public func updateSystem(
    _ item: FutureCashFlowItem, title: String, note: String?, amountMinor: Int64,
    expectedDate: String, status: FutureCashFlowStatus
  ) async -> Bool {
    guard let kind = item.systemKind, let referenceID = item.systemReferenceID else { return false }
    return await mutate {
      _ = try await self.repository.updateSystem(
        kind: kind, referenceID: referenceID,
        request: FutureCashFlowSystemReplace(
          title: title, note: note, plannedAmountMinor: amountMinor,
          expectedDate: expectedDate, status: status, expectedVersion: item.version))
    }
  }

  public func confirm(_ item: FutureCashFlowItem) async {
    guard let id = item.manualItemID else { return }
    _ = await mutate { _ = try await self.repository.confirm(id: id, version: item.version) }
  }

  public func cancel(
    _ item: FutureCashFlowItem, scope: FutureCashFlowMutationScope
  ) async {
    guard let id = item.manualItemID else { return }
    _ = await mutate {
      _ = try await self.repository.cancel(id: id, version: item.version, scope: scope)
    }
  }

  public func settle(
    _ item: FutureCashFlowItem, amountMinor: Int64, occurredAt: Date,
    accountID: UUID, destinationAccountID: UUID?, categoryID: UUID?
  ) async -> Bool {
    guard let id = item.manualItemID else { return false }
    return await mutate {
      _ = try await self.repository.settle(
        id: id,
        request: FutureCashFlowSettlement(
          version: item.version, amountMinor: amountMinor, occurredAt: occurredAt,
          accountID: accountID, destinationAccountID: destinationAccountID,
          categoryID: categoryID),
        idempotencyKey: UUID())
    }
  }

  public func clearMessage() { message = nil }

  @discardableResult
  private func mutate(_ action: () async throws -> Void) async -> Bool {
    isMutating = true; message = nil; defer { isMutating = false }
    do {
      try await action(); await load()
      if showingHistory { await loadHistory() }
      return true
    } catch { apply(error); return false }
  }

  private func apply(_ error: Error) {
    phase = active == nil ? .failed : .loaded
    message = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription
  }

  public static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
  public static func date(_ value: String) -> Date? { dayFormatter.date(from: value) }
  private static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return value
  }
  private static let monthFormatter: DateFormatter = {
    let value = DateFormatter(); value.calendar = calendar
    value.locale = .init(identifier: "en_US_POSIX"); value.timeZone = calendar.timeZone
    value.dateFormat = "yyyy-MM"; return value
  }()
  private static let monthParser: DateFormatter = {
    let value = DateFormatter(); value.calendar = calendar
    value.locale = .init(identifier: "en_US_POSIX"); value.timeZone = calendar.timeZone
    value.dateFormat = "yyyy-MM-dd"; return value
  }()
  private static let dayFormatter: DateFormatter = {
    let value = DateFormatter(); value.calendar = calendar
    value.locale = .init(identifier: "en_US_POSIX"); value.timeZone = calendar.timeZone
    value.dateFormat = "yyyy-MM-dd"; return value
  }()
}
