import AppKit
import FiscalKit
import SwiftUI

private actor SnapshotReportingRepository: ReportingRepository {
  let baseURL: URL
  let token: String

  init(baseURL: URL, token: String) {
    self.baseURL = baseURL
    self.token = token
  }

  func overview(month: String) async throws -> OverviewReport {
    try await request("reports/overview", ["month": month])
  }
  func spending(dateFrom: String, dateTo: String) async throws -> SpendingReport {
    try await request("reports/spending", ["date_from": dateFrom, "date_to": dateTo])
  }
  func cashFlow(dateFrom: String, dateTo: String, forecastDays: Int) async throws -> CashFlowReport {
    try await request("reports/cash-flow", [
      "date_from": dateFrom, "date_to": dateTo, "forecast_days": String(forecastDays),
    ])
  }
  func debt(asOf: String) async throws -> DebtReport {
    try await request("reports/debt", ["as_of": asOf])
  }
  func drillDown(
    lens: ReportLens, dateFrom: String, dateTo: String, categoryID: UUID?, accountID: UUID?,
    cursor: String?, limit: Int
  ) async throws -> ReportDrillDownPage {
    var query = [
      "lens": lens.rawValue, "date_from": dateFrom, "date_to": dateTo,
      "limit": String(limit),
    ]
    query["category_id"] = categoryID?.uuidString
    query["account_id"] = accountID?.uuidString
    query["cursor"] = cursor
    return try await request("reports/drill-down", query)
  }

  private func request<Value: Decodable>(_ path: String, _ query: [String: String?]) async throws
    -> Value
  {
    var components = URLComponents(
      url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
    components.queryItems = query.compactMap { key, value in
      value.map { URLQueryItem(name: key, value: $0) }
    }
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else { throw CocoaError(.fileReadUnknown) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Value.self, from: data)
  }
}

@main
private struct FiscalSnapshotTool {
  @MainActor
  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    let token = environment["FISCAL_DEVICE_TOKEN"] ?? "integration-device-token"
    let output = URL(
      fileURLWithPath: environment["FISCAL_QA_SCREENSHOT_DIR"]
        ?? "../docs/qa/p7/screenshots", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let repository = SnapshotReportingRepository(
      baseURL: URL(string: environment["FISCAL_API_BASE_URL"] ?? "http://127.0.0.1:8000")!,
      token: token)
    let model = ReportingModel(repository: repository)
    await model.loadAll()

    try render(
      MacReportingOverviewScreen(model: model, navigate: { _ in }),
      to: output.appendingPathComponent("macos-p7-overview.png"))
    try render(
      MacCashFlowScreen(model: model),
      to: output.appendingPathComponent("macos-p7-cash-flow.png"))
    model.lens = .spending
    try render(
      MacReportsScreen(model: model),
      to: output.appendingPathComponent("macos-p7-reports.png"))
    model.lens = .cashFlow
    try render(
      MacReportsScreen(model: model),
      to: output.appendingPathComponent("macos-p7-cash-report.png"))
    model.lens = .debt
    try render(
      MacReportsScreen(model: model),
      to: output.appendingPathComponent("macos-p7-debt.png"))
    if let categoryID = model.spending?.categories.first?.categoryID {
      model.lens = .spending
      await model.loadDrillDown(categoryID: categoryID)
      try render(
        MacReportsScreen(model: model),
        to: output.appendingPathComponent("macos-p7-drill-down.png"))
    }
  }

  @MainActor
  private static func render<V: View>(_ view: V, to url: URL) throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let hosting = NSHostingView(
      rootView: ZStack { FiscalColor.macBackground; view }
        .frame(width: 830, height: 700).environment(\.colorScheme, .light))
    hosting.frame = NSRect(x: 0, y: 0, width: 830, height: 700)
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor(
      calibratedRed: 0.965, green: 0.973, blue: 0.984, alpha: 1).cgColor
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .white
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
  }
}
