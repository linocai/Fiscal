import Foundation
import Observation

public struct StatementImportWorkbench: Codable, Sendable, Equatable {
  public struct Row: Codable, Sendable, Equatable, Identifiable {
    public struct Draft: Codable, Sendable, Equatable { public let id: UUID; public let resolution: String; public let version: Int }
    public struct Candidate: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let candidateKind: String; public let transactionID: UUID?
      enum CodingKeys: String, CodingKey { case id; case candidateKind = "candidate_kind"; case transactionID = "transaction_id" } }
    public let id: UUID; public let rowNumber: Int; public let pageNumber: Int?; public let rowVersion: Int
    public let sourceKind: String?; public let evidenceTextMasked: String?; public let draft: Draft?; public let candidates: [Candidate]; public let finalCreateDraftVersion: Int?; public let isConfirmed: Bool
    enum CodingKeys: String, CodingKey { case id, draft, candidates; case rowNumber = "row_number"; case pageNumber = "page_number"; case rowVersion = "row_version"; case sourceKind = "source_kind"; case evidenceTextMasked = "evidence_text_masked"; case finalCreateDraftVersion = "final_create_draft_version"; case isConfirmed = "is_confirmed" }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(UUID.self, forKey: .id); rowNumber = try c.decode(Int.self, forKey: .rowNumber)
      pageNumber = try c.decodeIfPresent(Int.self, forKey: .pageNumber); rowVersion = try c.decode(Int.self, forKey: .rowVersion)
      sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
      evidenceTextMasked = try c.decodeIfPresent(String.self, forKey: .evidenceTextMasked)
      draft = try c.decodeIfPresent(Draft.self, forKey: .draft); candidates = try c.decode([Candidate].self, forKey: .candidates)
      finalCreateDraftVersion = try c.decodeIfPresent(Int.self, forKey: .finalCreateDraftVersion)
      isConfirmed = try c.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false
    }
  }
  public let batchID: UUID; public let batchVersion: Int; public let reviewAvailable: Bool; public let rows: [Row]; public let nextCursor: Int?
  enum CodingKeys: String, CodingKey { case rows; case batchID = "batch_id"; case batchVersion = "batch_version"; case reviewAvailable = "review_available"; case nextCursor = "next_cursor" }
}

public struct RemoteStatementImportConfirmationRepository: StatementImportConfirmationRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }
  public func preview(batchID: UUID, rowIDs: [UUID]) async throws -> StatementImportConfirmationPreview {
    try await transport.request("statement-imports/\(batchID)/confirmation-preview", method: "POST", cache: false, body: PreviewRequest(rowIDs: rowIDs))
  }
  public func receipt(batchID: UUID, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt {
    try await transport.request("statement-imports/\(batchID)/confirmation-receipt", headers: ["Idempotency-Key": idempotencyKey.uuidString], cache: false)
  }
  public func confirm(batchID: UUID, request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws -> StatementImportConfirmationReceipt {
    try await transport.request("statement-imports/\(batchID)/confirm", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString], cache: false, body: request)
  }
  public func confirm(_ request: StatementImportConfirmationDTO, idempotencyKey: UUID) async throws { _ = request; _ = idempotencyKey; throw FiscalAPIError.invalidResponse }
  private struct PreviewRequest: Codable, Sendable { let rowIDs: [UUID]; enum CodingKeys: String, CodingKey { case rowIDs = "row_ids" } }
}

public struct StatementImportWorkbenchPage: Codable, Sendable, Equatable {
  public let pageNumber: Int; public let sourceAvailable: Bool; public let sourceKind: String?; public let evidenceTextMasked: String?
  enum CodingKeys: String, CodingKey { case pageNumber = "page_number"; case sourceAvailable = "source_available"; case sourceKind = "source_kind"; case evidenceTextMasked = "evidence_text_masked" }
}

public protocol StatementImportReviewWorkbenchRepository: Sendable {
  func workbench(batchID: UUID, cursor: Int, limit: Int, filters: [String: String]) async throws -> StatementImportWorkbench
  func page(batchID: UUID, pageNumber: Int) async throws -> StatementImportWorkbenchPage
}

public struct RemoteStatementImportReviewWorkbenchRepository: StatementImportReviewWorkbenchRepository {
  private let transport: APITransport; public init(transport: APITransport) { self.transport = transport }
  public func workbench(batchID: UUID, cursor: Int = 0, limit: Int = 100, filters: [String: String] = [:]) async throws -> StatementImportWorkbench {
    var query = [URLQueryItem(name: "cursor", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))]
    if !filters.isEmpty { query.append(.init(name: "filters", value: String(data: try JSONEncoder().encode(filters), encoding: .utf8))) }
    return try await transport.request("statement-imports/\(batchID)/review-workbench", query: query, cache: false)
  }
  public func page(batchID: UUID, pageNumber: Int) async throws -> StatementImportWorkbenchPage {
    try await transport.request("statement-imports/\(batchID)/review-workbench/pages/\(pageNumber)", cache: false)
  }
}

@MainActor @Observable public final class StatementImportReviewWorkbenchModel {
  public private(set) var workbench: StatementImportWorkbench?; public private(set) var selectedRowID: UUID?; public private(set) var page: StatementImportWorkbenchPage?; public private(set) var error: String?
  private let repository: any StatementImportReviewWorkbenchRepository
  private let resolutionRepository: (any StatementImportDraftResolutionRepository)?
  private let finalDraftRepository: (any StatementImportFinalCreateDraftRepository)?
  private let confirmationRepository: (any StatementImportConfirmationRepository)?
  public private(set) var confirmationPreview: StatementImportConfirmationPreview?
  public private(set) var confirmationReceipt: StatementImportConfirmationReceipt?
  public private(set) var responseUnknownConfirmationKey: UUID?
  public init(
    repository: any StatementImportReviewWorkbenchRepository,
    resolutionRepository: (any StatementImportDraftResolutionRepository)? = nil,
    finalDraftRepository: (any StatementImportFinalCreateDraftRepository)? = nil,
    confirmationRepository: (any StatementImportConfirmationRepository)? = nil
  ) {
    self.repository = repository
    self.resolutionRepository = resolutionRepository
    self.finalDraftRepository = finalDraftRepository
    self.confirmationRepository = confirmationRepository
  }
  public func reload(batchID: UUID, preservingError: Bool = false) async { do { workbench = try await repository.workbench(batchID: batchID, cursor: 0, limit: 100, filters: [:]); if !preservingError { self.error = nil } } catch { self.error = "无法刷新审核数据。" } }
  public func select(_ row: StatementImportWorkbench.Row) async { selectedRowID = row.id; guard let pageNumber = row.pageNumber, let workbench else { page = nil; return }; do { page = try await repository.page(batchID: workbench.batchID, pageNumber: pageNumber) } catch { self.error = "脱敏来源不可用。" } }
  @discardableResult public func saveResolution(
    rowID: UUID, resolution: StatementImportDraftResolutionKind,
    matchedTransactionID: UUID? = nil, ignoredReason: String? = nil
  ) async -> Bool {
    guard let resolutionRepository, let workbench else { error = "审核写入不可用。"; return false }
    do {
      _ = try await resolutionRepository.putResolution(
        batchID: workbench.batchID, rowID: rowID, resolution: resolution,
        matchedTransactionID: matchedTransactionID, ignoredReason: ignoredReason)
      await reload(batchID: workbench.batchID); return true
    } catch {
      if Self.isConflict(error) {
        self.error = "服务器已变化，请重新选择后再提交。"
        await reload(batchID: workbench.batchID, preservingError: true)
      } else { self.error = "无法保存审核选择。" }
      return false
    }
  }
  public func saveFinalCreateDraft(rowID: UUID, transaction: TransactionDraft) async {
    guard let finalDraftRepository, let workbench else { error = "新建草稿不可用。"; return }
    do {
      _ = try await finalDraftRepository.putFinalCreateDraft(
        batchID: workbench.batchID, rowID: rowID, transaction: transaction)
      await reload(batchID: workbench.batchID)
    } catch {
      if Self.isConflict(error) {
        self.error = "服务器已变化，请重新选择后再提交。"
        await reload(batchID: workbench.batchID, preservingError: true)
      } else { self.error = "无法保存新建草稿。" }
    }
  }
  @discardableResult public func prepareConfirmation(batchID: UUID, rowIDs: Set<UUID>) async -> Bool {
    guard !rowIDs.isEmpty, let confirmationRepository else { error = "请选择至少一条已解决且未冻结的行。"; return false }
    await reload(batchID: batchID)
    guard let workbench, workbench.reviewAvailable,
      rowIDs.allSatisfy({ id in workbench.rows.contains { $0.id == id && !$0.isConfirmed && $0.draft?.resolution != nil && $0.draft?.resolution != "unresolved" } })
    else { error = "服务器已变化，请重新选择后再确认。"; return false }
    do { confirmationPreview = try await confirmationRepository.preview(batchID: batchID, rowIDs: rowIDs.sorted { $0.uuidString < $1.uuidString }); confirmationReceipt = nil; responseUnknownConfirmationKey = nil; error = nil; return true }
    catch { if Self.isConflict(error) { confirmationPreview = nil; self.error = "服务器已变化，请重新选择后再确认。"; await reload(batchID: batchID, preservingError: true) } else { self.error = "无法准备确认预览。" }; return false }
  }
  @discardableResult public func confirmPrepared() async -> Bool {
    guard let confirmationRepository, let preview = confirmationPreview else { return false }
    let key = UUID(); responseUnknownConfirmationKey = key
    do { confirmationReceipt = try await confirmationRepository.confirm(batchID: preview.batchID, request: preview.request, idempotencyKey: key); confirmationPreview = nil; responseUnknownConfirmationKey = nil; await reload(batchID: preview.batchID); return true }
    catch { if Self.isConflict(error) { confirmationPreview = nil; self.error = "服务器已变化，请重新选择后再确认。"; await reload(batchID: preview.batchID, preservingError: true) } else { self.error = "确认响应未知；不会自动重发。可显式查询收据。" }; return false }
  }
  @discardableResult public func lookupConfirmationReceipt() async -> Bool {
    guard let confirmationRepository, let workbench, let key = responseUnknownConfirmationKey else { return false }
    do { confirmationReceipt = try await confirmationRepository.receipt(batchID: workbench.batchID, idempotencyKey: key); confirmationPreview = nil; responseUnknownConfirmationKey = nil; await reload(batchID: workbench.batchID); return true }
    catch { self.error = "尚未找到已持久化的确认收据。"; return false }
  }
  public func clear() { workbench = nil; selectedRowID = nil; page = nil; error = nil; confirmationPreview = nil; confirmationReceipt = nil; responseUnknownConfirmationKey = nil }
  private static func isConflict(_ error: Error) -> Bool {
    guard case .domain(let status, _) = error as? FiscalAPIError else { return false }
    return status == 409
  }
}
