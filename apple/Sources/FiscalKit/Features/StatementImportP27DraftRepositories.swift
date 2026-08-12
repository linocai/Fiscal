import Foundation

/// The five server-defined choices.  This deliberately does not contain a confirmation action.
public enum StatementImportDraftResolutionKind: String, Codable, Sendable, CaseIterable, Identifiable {
  case unresolved, createNew = "create_new", matchExisting = "match_existing"
  case ignoreNonTransaction = "ignore_non_transaction", ignoreIntentional = "ignore_intentional"
  public var id: Self { self }
}

public struct StatementImportDraftResolutionRequest: Codable, Sendable, Equatable {
  public let expectedBatchVersion: Int
  public let expectedRowVersion: Int
  public let expectedResolutionVersion: Int
  public let resolution: StatementImportDraftResolutionKind
  public let matchedTransactionID: UUID?
  public let ignoredReason: String?
  enum CodingKeys: String, CodingKey {
    case expectedBatchVersion = "expected_batch_version"
    case expectedRowVersion = "expected_row_version"
    case expectedResolutionVersion = "expected_resolution_version"
    case resolution
    case matchedTransactionID = "matched_transaction_id"
    case ignoredReason = "ignored_reason"
  }
}

public protocol StatementImportDraftResolutionRepository: Sendable {
  func putResolution(
    batchID: UUID, rowID: UUID, resolution: StatementImportDraftResolutionKind,
    matchedTransactionID: UUID?, ignoredReason: String?
  ) async throws -> StatementImportReviewDTO
}

/// A P27 write adapter.  It always reloads the un-cached workbench immediately before a PUT,
/// rather than trusting a selected row held by SwiftUI.
public struct RemoteStatementImportDraftResolutionRepository: StatementImportDraftResolutionRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }

  public func putResolution(
    batchID: UUID, rowID: UUID, resolution: StatementImportDraftResolutionKind,
    matchedTransactionID: UUID?, ignoredReason: String?
  ) async throws -> StatementImportReviewDTO {
    let fresh: StatementImportWorkbench = try await transport.request(
      "statement-imports/\(batchID)/review-workbench",
      query: [.init(name: "cursor", value: "0"), .init(name: "limit", value: "200")], cache: false)
    guard let row = fresh.rows.first(where: { $0.id == rowID }) else { throw FiscalAPIError.invalidResponse }
    let request = StatementImportDraftResolutionRequest(
      expectedBatchVersion: fresh.batchVersion, expectedRowVersion: row.rowVersion,
      expectedResolutionVersion: row.draft?.version ?? 0, resolution: resolution,
      matchedTransactionID: matchedTransactionID, ignoredReason: ignoredReason)
    let response: StatementImportReviewDTO = try await transport.request(
      "statement-imports/\(batchID)/rows/\(rowID)/draft-resolution", method: "PUT", body: request)
    return response
  }
}

public struct StatementImportFinalCreateDraftRequest: Codable, Sendable, Equatable {
  public let expectedVersion: Int
  public let transaction: TransactionDraft
  enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", transaction }
}

public struct StatementImportFinalCreateDraftDTO: Codable, Sendable, Equatable {
  public let id: UUID
  public let statementImportRowID: UUID
  public let draftResolutionID: UUID
  public let transaction: TransactionDraft
  public let version: Int
  enum CodingKeys: String, CodingKey {
    case id, transaction, version
    case statementImportRowID = "statement_import_row_id"
    case draftResolutionID = "draft_resolution_id"
  }
}

public protocol StatementImportFinalCreateDraftRepository: Sendable {
  func putFinalCreateDraft(batchID: UUID, rowID: UUID, transaction: TransactionDraft) async throws -> StatementImportFinalCreateDraftDTO
}

/// P27 final-create drafts remain a separate write seam.  It also obtains the current version
/// from an uncached workbench read; a missing row never becomes a write with a guessed version.
public struct RemoteStatementImportFinalCreateDraftRepository: StatementImportFinalCreateDraftRepository {
  private let transport: APITransport
  public init(transport: APITransport) { self.transport = transport }
  public func putFinalCreateDraft(batchID: UUID, rowID: UUID, transaction: TransactionDraft) async throws -> StatementImportFinalCreateDraftDTO {
    let fresh: StatementImportWorkbench = try await transport.request(
      "statement-imports/\(batchID)/review-workbench",
      query: [.init(name: "cursor", value: "0"), .init(name: "limit", value: "200")], cache: false)
    guard let row = fresh.rows.first(where: { $0.id == rowID }) else { throw FiscalAPIError.invalidResponse }
    return try await transport.request(
      "statement-imports/\(batchID)/rows/\(rowID)/final-create-draft", method: "PUT",
      body: StatementImportFinalCreateDraftRequest(
        expectedVersion: row.finalCreateDraftVersion ?? 0, transaction: transaction))
  }
}
