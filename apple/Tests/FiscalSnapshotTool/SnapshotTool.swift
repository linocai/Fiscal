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

private actor SnapshotAIRepository: AIProposalRepository, AISettingsRepository {
  let baseURL: URL
  let token: String
  init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }

  func list(status: AIProposalStatus?, cursor: String?, limit: Int) async throws -> AIProposalPage {
    var query = ["limit": String(limit)]
    query["status"] = status?.rawValue; query["cursor"] = cursor
    return try await request("ai/proposals", query: query)
  }
  func get(id: UUID) async throws -> AIProposalDTO { try await request("ai/proposals/\(id)") }
  func create(text: String, idempotencyKey: UUID) async throws -> AIProposalDTO {
    try await request("ai/proposals", method: "POST", body: AIProposalCreateRequest(text: text), headers: ["Idempotency-Key": idempotencyKey.uuidString])
  }
  func update(id: UUID, request value: AIProposalReplacementRequest) async throws -> AIProposalDTO {
    try await request("ai/proposals/\(id)", method: "PUT", body: value)
  }
  func action(id: UUID, action: String, expectedVersion: Int) async throws -> AIProposalActionResponse {
    if action == "execute" || action == "undo" {
      return try await request("ai/proposals/\(id)/\(action)", method: "POST", body: VersionRequest(version: expectedVersion))
    }
    let proposal: AIProposalDTO = try await request("ai/proposals/\(id)/\(action)", method: "POST", body: VersionRequest(version: expectedVersion))
    return AIProposalActionResponse(proposal: proposal, transaction: nil)
  }
  func get() async throws -> AISettingsDTO { try await request("ai/settings") }
  func update(_ value: AISettingsUpdateRequest) async throws -> AISettingsDTO {
    try await request("ai/settings", method: "PUT", body: value)
  }
  private func request<Value: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> Value {
    try await request(path, method: "GET", body: Optional<String>.none, query: query)
  }
  private func request<Value: Decodable, Body: Encodable>(
    _ path: String, method: String, body: Body, query: [String: String?] = [:],
    headers: [String: String] = [:]
  ) async throws -> Value {
    var components = URLComponents(url: baseURL.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
    components.queryItems = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
    var request = URLRequest(url: components.url!); request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if method != "GET" { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw CocoaError(.fileReadUnknown) }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
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
        ?? "../docs/qa/p9/screenshots", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let baseURL = URL(string: environment["FISCAL_API_BASE_URL"] ?? "http://127.0.0.1:8000")!
    let tokenStore = KeychainTokenStore(service: "com.linotsai.fiscal.snapshot")
    try await tokenStore.save(token)
    let transport = APITransport(baseURL: baseURL, tokenStore: tokenStore)
    let accountsModel = AccountsModel(repository: RemoteAccountRepository(transport: transport))
    let categoriesModel = CategoriesModel(repository: RemoteCategoryRepository(transport: transport))
    let creditModel = CreditModel(repository: RemoteCreditRepository(transport: transport))
    let repository = SnapshotReportingRepository(
      baseURL: baseURL,
      token: token)
    let model = ReportingModel(repository: repository)
    await model.loadAll()
    let aiRepository = SnapshotAIRepository(baseURL: baseURL, token: token)
    let aiModel = AIProposalModel(repository: aiRepository)
    let settingsModel = AISettingsModel(repository: aiRepository)
    async let proposalLoad: Void = aiModel.load()
    async let settingsLoad: Void = settingsModel.load()
    async let accountLoad: Void = accountsModel.load()
    async let categoryLoad: Void = categoriesModel.load()
    async let creditLoad: Void = creditModel.loadAccounts()
    _ = await (proposalLoad, settingsLoad, accountLoad, categoryLoad, creditLoad)

    let aiScreenshot = output.appendingPathComponent("macos-p9-ai-ocr.png")
    try render(
      MacAIProposalScreen(model: aiModel, accounts: accountsModel, categories: categoriesModel, credit: creditModel),
      to: aiScreenshot)
    try render(
      MacSettingsScreen(model: settingsModel),
      to: output.appendingPathComponent("macos-p9-settings-sources.png"))
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
