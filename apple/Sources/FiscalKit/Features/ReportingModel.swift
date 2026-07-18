import Foundation
import Observation

public enum ReportingPhase: Sendable, Equatable { case idle, loading, loaded, empty, failed }

@MainActor
@Observable
public final class ReportingModel {
  public private(set) var overview: OverviewReport?
  public private(set) var spending: SpendingReport?
  // Compatibility-only DTO storage for unreferenced legacy helpers. P18 no longer loads these
  // endpoints for reports or overview.
  public private(set) var cashFlow: CashFlowReport?
  public private(set) var debt: DebtReport?
  public private(set) var drillDown: ReportDrillDownPage?
  public private(set) var phase: ReportingPhase = .idle
  public private(set) var message: String?
  public private(set) var refreshMessage: String?
  public private(set) var loadingMore = false
  public var lens: ReportLens = .spending {
    // Drill-down belongs to one lens; changing lens must drop it so "加载更多" can't issue a mixed
    // request (new lens + a stale drillCategoryID) and render two calibres in one list (M8).
    didSet { if oldValue != lens { clearDrillDown() } }
  }
  public private(set) var month: String
  public private(set) var dateFrom: String
  public private(set) var dateTo: String

  private let repository: any ReportingRepository
  private var overviewGeneration = 0
  private var spendingGeneration = 0
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
    async let overviewLoad: Void = loadOverview()
    async let spendingLoad: Void = loadSpending()
    _ = await (overviewLoad, spendingLoad)
  }

  public func loadOverview() async {
    overviewGeneration += 1
    let current = overviewGeneration
    let snapshot = month
    phase = overview == nil ? .loading : .loaded
    message = nil
    refreshMessage = nil
    do {
      let loaded = try await repository.overview(month: snapshot)
      guard current == overviewGeneration, snapshot == month else { return }
      overview = loaded
      phase = loaded.recentTransactions.isEmpty ? .empty : .loaded
    } catch is CancellationError {
      if current == overviewGeneration, overview == nil { phase = .idle }
    } catch {
      guard current == overviewGeneration else { return }
      if overview == nil { phase = .failed; message = Self.display(error) }
      else { phase = .loaded; refreshMessage = Self.display(error) }
    }
  }

  public func loadSpending() async {
    spendingGeneration += 1
    let current = spendingGeneration
    let snapshot = (dateFrom, dateTo)
    phase = spending == nil ? .loading : .loaded
    message = nil; refreshMessage = nil
    do {
      let loaded = try await repository.spending(dateFrom: snapshot.0, dateTo: snapshot.1)
      guard current == spendingGeneration, snapshot == (dateFrom, dateTo) else { return }
      spending = loaded
      phase = loaded.categories.isEmpty && loaded.uncategorized.transactionCount == 0 ? .empty : .loaded
    } catch is CancellationError {
      if current == spendingGeneration, spending == nil { phase = .idle }
    } catch {
      guard current == spendingGeneration else { return }
      if spending == nil { phase = .failed; message = Self.display(error) }
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
    await loadSpending()
  }

  public func returnToCurrentMonth(now: Date = Date()) async {
    let range = Self.monthRange(containing: now)
    month = range.month
    dateFrom = range.dateFrom
    dateTo = range.dateTo
    clearDrillDown()
    await loadSpending()
  }

  public func ensureCurrentMonth(now: Date = Date()) async {
    let range = Self.monthRange(containing: now)
    guard month != range.month || dateFrom != range.dateFrom || dateTo != range.dateTo else {
      return
    }
    await returnToCurrentMonth(now: now)
  }

  public func loadDrillDown(categoryID: UUID? = nil, accountID: UUID? = nil) async {
    guard lens == .spending else { return }
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

@MainActor
public final class ReportingInvalidationCoordinator {
  private let overview: ReportingModel
  private let spending: ReportingModel
  public init(overview: ReportingModel, spending: ReportingModel) {
    self.overview = overview; self.spending = spending
  }
  public func refresh() async {
    async let overviewLoad: Void = overview.loadOverview()
    async let spendingLoad: Void = spending.loadSpending()
    _ = await (overviewLoad, spendingLoad)
  }
}
