import Foundation

public protocol ReportingRepository: Sendable {
  func overview(month: String) async throws -> OverviewReport
  func spending(dateFrom: String, dateTo: String) async throws -> SpendingReport
  func cashFlow(dateFrom: String, dateTo: String, forecastDays: Int) async throws
    -> CashFlowReport
  func debt(asOf: String) async throws -> DebtReport
  func drillDown(
    lens: ReportLens, dateFrom: String, dateTo: String, categoryID: UUID?, accountID: UUID?,
    cursor: String?, limit: Int
  ) async throws -> ReportDrillDownPage
}

public actor RemoteReportingRepository: ReportingRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }

  public func overview(month: String) async throws -> OverviewReport {
    try await transport.request(
      "reports/overview", query: [.init(name: "month", value: month)])
  }
  public func spending(dateFrom: String, dateTo: String) async throws -> SpendingReport {
    try await transport.request(
      "reports/spending",
      query: [
        .init(name: "date_from", value: dateFrom), .init(name: "date_to", value: dateTo),
      ])
  }
  public func cashFlow(
    dateFrom: String, dateTo: String, forecastDays: Int
  ) async throws -> CashFlowReport {
    try await transport.request(
      "reports/cash-flow",
      query: [
        .init(name: "date_from", value: dateFrom), .init(name: "date_to", value: dateTo),
        .init(name: "forecast_days", value: String(forecastDays)),
      ])
  }
  public func debt(asOf: String) async throws -> DebtReport {
    try await transport.request("reports/debt", query: [.init(name: "as_of", value: asOf)])
  }
  public func drillDown(
    lens: ReportLens, dateFrom: String, dateTo: String, categoryID: UUID?, accountID: UUID?,
    cursor: String?, limit: Int = 50
  ) async throws -> ReportDrillDownPage {
    var query = [
      URLQueryItem(name: "lens", value: lens.rawValue),
      .init(name: "date_from", value: dateFrom), .init(name: "date_to", value: dateTo),
      .init(name: "limit", value: String(limit)),
    ]
    if let categoryID { query.append(.init(name: "category_id", value: categoryID.uuidString)) }
    if let accountID { query.append(.init(name: "account_id", value: accountID.uuidString)) }
    if let cursor { query.append(.init(name: "cursor", value: cursor)) }
    return try await transport.request("reports/drill-down", query: query)
  }
}
