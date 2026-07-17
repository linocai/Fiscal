import Foundation
import Observation

public enum ReportingPhase: Sendable, Equatable { case idle, loading, loaded, empty, failed }

@MainActor
@Observable
public final class ReportingModel {
  public private(set) var overview: OverviewReport?
  public private(set) var spending: SpendingReport?
  public private(set) var cashFlow: CashFlowReport?
  public private(set) var debt: DebtReport?
  public private(set) var drillDown: ReportDrillDownPage?
  public private(set) var phase: ReportingPhase = .idle
  public private(set) var message: String?
  public private(set) var refreshMessage: String?
  public private(set) var loadingMore = false
  public var lens: ReportLens = .spending
  public private(set) var month: String
  public private(set) var dateFrom: String
  public private(set) var dateTo: String

  private let repository: any ReportingRepository
  private var generation = 0
  private var drillGeneration = 0
  private var drillCategoryID: UUID?
  private var drillAccountID: UUID?

  public init(repository: any ReportingRepository, now: Date = Date()) {
    self.repository = repository
    let range = Self.monthRange(containing: now)
    month = range.month
    dateFrom = range.dateFrom
    dateTo = range.dateTo
  }

  public func loadAll() async {
    generation += 1
    let current = generation
    let snapshot = (month, dateFrom, dateTo)
    phase = overview == nil ? .loading : .loaded
    message = nil
    refreshMessage = nil
    do {
      async let nextOverview = repository.overview(month: snapshot.0)
      async let nextSpending = repository.spending(dateFrom: snapshot.1, dateTo: snapshot.2)
      async let nextCash = repository.cashFlow(
        dateFrom: snapshot.1, dateTo: snapshot.2, forecastDays: 30)
      async let nextDebt = repository.debt(asOf: snapshot.2)
      let loaded = try await (nextOverview, nextSpending, nextCash, nextDebt)
      guard current == generation, snapshot == (month, dateFrom, dateTo) else { return }
      overview = loaded.0
      spending = loaded.1
      cashFlow = loaded.2
      debt = loaded.3
      phase = Self.isEmpty(loaded.0, loaded.1, loaded.2, loaded.3) ? .empty : .loaded
    } catch is CancellationError {
      if current == generation, overview == nil { phase = .idle }
    } catch {
      guard current == generation else { return }
      if overview == nil { phase = .failed; message = Self.display(error) }
      else { phase = .loaded; refreshMessage = Self.display(error) }
    }
  }

  public func moveMonth(by value: Int) async {
    guard let anchor = Self.monthParser.date(from: "\(month)-01"),
      let shifted = Self.calendar.date(byAdding: .month, value: value, to: anchor)
    else { return }
    let range = Self.monthRange(containing: shifted)
    month = range.month
    dateFrom = range.dateFrom
    dateTo = range.dateTo
    clearDrillDown()
    await loadAll()
  }

  public func returnToCurrentMonth(now: Date = Date()) async {
    let range = Self.monthRange(containing: now)
    month = range.month
    dateFrom = range.dateFrom
    dateTo = range.dateTo
    clearDrillDown()
    await loadAll()
  }

  public func ensureCurrentMonth(now: Date = Date()) async {
    let range = Self.monthRange(containing: now)
    guard month != range.month || dateFrom != range.dateFrom || dateTo != range.dateTo else {
      return
    }
    await returnToCurrentMonth(now: now)
  }

  public func loadDrillDown(categoryID: UUID? = nil, accountID: UUID? = nil) async {
    guard lens != .debt else { return }
    drillGeneration += 1
    let current = drillGeneration
    let snapshot = (lens, dateFrom, dateTo, categoryID, accountID)
    drillDown = nil
    drillCategoryID = categoryID
    drillAccountID = accountID
    do {
      let page = try await repository.drillDown(
        lens: snapshot.0, dateFrom: snapshot.1, dateTo: snapshot.2,
        categoryID: snapshot.3, accountID: snapshot.4, cursor: nil, limit: 50)
      guard current == drillGeneration, snapshot.0 == lens, snapshot.1 == dateFrom,
        snapshot.2 == dateTo
      else { return }
      drillDown = page
    } catch is CancellationError {} catch {
      if current == drillGeneration { refreshMessage = Self.display(error) }
    }
  }

  public func loadMoreDrillDown() async {
    guard let currentPage = drillDown, let cursor = currentPage.nextCursor, !loadingMore else {
      return
    }
    let current = drillGeneration
    loadingMore = true
    defer { loadingMore = false }
    do {
      let page = try await repository.drillDown(
        lens: lens, dateFrom: dateFrom, dateTo: dateTo,
        categoryID: drillCategoryID, accountID: drillAccountID, cursor: cursor, limit: 50)
      guard current == drillGeneration else { return }
      let known = Set(currentPage.items.map(\.id))
      drillDown = ReportDrillDownPage(
        items: currentPage.items + page.items.filter { !known.contains($0.id) },
        nextCursor: page.nextCursor)
    } catch { if current == drillGeneration { refreshMessage = Self.display(error) } }
  }

  public func clearDrillDown() {
    drillGeneration += 1
    drillDown = nil
    drillCategoryID = nil
    drillAccountID = nil
  }
  public func clearRefreshMessage() { refreshMessage = nil }

  static func monthRange(containing date: Date) -> (month: String, dateFrom: String, dateTo: String) {
    let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
    return (monthFormatter.string(from: start), dayFormatter.string(from: start), dayFormatter.string(from: end))
  }

  private static func isEmpty(
    _ overview: OverviewReport, _ spending: SpendingReport, _ cash: CashFlowReport,
    _ debt: DebtReport
  ) -> Bool {
    overview.recentTransactions.isEmpty && spending.totals.grossConsumptionMinor == 0
      && cash.actual.inflowMinor == 0 && cash.actual.outflowMinor == 0
      && debt.currentCreditDebtMinor == 0
  }
  private static func display(_ error: Error) -> String {
    (error as? FiscalAPIError)?.displayMessage ?? "报表暂时无法加载。"
  }
  private static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return value
  }
  private static let monthFormatter: DateFormatter = {
    let value = DateFormatter(); value.calendar = calendar; value.locale = .init(identifier: "en_US_POSIX")
    value.timeZone = calendar.timeZone; value.dateFormat = "yyyy-MM"; return value
  }()
  private static let dayFormatter: DateFormatter = {
    let value = DateFormatter(); value.calendar = calendar; value.locale = .init(identifier: "en_US_POSIX")
    value.timeZone = calendar.timeZone; value.dateFormat = "yyyy-MM-dd"; return value
  }()
  private static let monthParser: DateFormatter = {
    let value = DateFormatter(); value.calendar = calendar; value.locale = .init(identifier: "en_US_POSIX")
    value.timeZone = calendar.timeZone; value.dateFormat = "yyyy-MM-dd"; return value
  }()
}
