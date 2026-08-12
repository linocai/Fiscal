import Foundation
import Observation

public struct StatementImportWorkbench: Codable, Sendable, Equatable {
  public struct Row: Codable, Sendable, Equatable, Identifiable {
    public struct Draft: Codable, Sendable, Equatable { public let id: UUID; public let resolution: String; public let version: Int }
    public struct Candidate: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let candidateKind: String; public let transactionID: UUID?
      enum CodingKeys: String, CodingKey { case id; case candidateKind = "candidate_kind"; case transactionID = "transaction_id" } }
    public let id: UUID; public let rowNumber: Int; public let pageNumber: Int?; public let rowVersion: Int
    public let sourceKind: String?; public let evidenceTextMasked: String?; public let draft: Draft?; public let candidates: [Candidate]; public let finalCreateDraftVersion: Int?
    enum CodingKeys: String, CodingKey { case id, draft, candidates; case rowNumber = "row_number"; case pageNumber = "page_number"; case rowVersion = "row_version"; case sourceKind = "source_kind"; case evidenceTextMasked = "evidence_text_masked"; case finalCreateDraftVersion = "final_create_draft_version" }
  }
  public let batchID: UUID; public let batchVersion: Int; public let reviewAvailable: Bool; public let rows: [Row]; public let nextCursor: Int?
  enum CodingKeys: String, CodingKey { case rows; case batchID = "batch_id"; case batchVersion = "batch_version"; case reviewAvailable = "review_available"; case nextCursor = "next_cursor" }
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
  public init(
    repository: any StatementImportReviewWorkbenchRepository,
    resolutionRepository: (any StatementImportDraftResolutionRepository)? = nil,
    finalDraftRepository: (any StatementImportFinalCreateDraftRepository)? = nil
  ) {
    self.repository = repository
    self.resolutionRepository = resolutionRepository
    self.finalDraftRepository = finalDraftRepository
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
  public func clear() { workbench = nil; selectedRowID = nil; page = nil; error = nil }
  private static func isConflict(_ error: Error) -> Bool {
    guard case .domain(let status, _) = error as? FiscalAPIError else { return false }
    return status == 409
  }
}
