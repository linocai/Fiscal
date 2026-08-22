import Foundation

// MARK: - P24–P28 statement import contracts
//
// These are deliberately schema-shaped and intentionally omit every raw-file
// surface. A Feature can send metadata and masked evidence only.

public enum V15StatementImportStatus: Sendable, Equatable, Decodable {
    case created, extracting, parsing, reviewRequired, readyToConfirm, partiallyConfirmed, confirmed, failed, abandoned, unknown(String)
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "created": self = .created; case "extracting": self = .extracting; case "parsing": self = .parsing
        case "review_required": self = .reviewRequired; case "ready_to_confirm": self = .readyToConfirm
        case "partially_confirmed": self = .partiallyConfirmed; case "confirmed": self = .confirmed
        case "failed": self = .failed; case "abandoned": self = .abandoned; case let value: self = .unknown(value)
        }
    }
    public var displayName: String { switch self {
    case .created: "已登记"; case .extracting: "本地提取中"; case .parsing: "解析中"; case .reviewRequired: "需要复核"
    case .readyToConfirm: "可确认"; case .partiallyConfirmed: "部分已确认"; case .confirmed: "已确认"
    case .failed: "失败"; case .abandoned: "已取消"; case .unknown(let value): "未知状态（\(value)）"
    } }
    public var isDisplayOnly: Bool { if case .unknown = self { true } else { false } }
}

public enum V15StatementResolution: Sendable, Equatable, Decodable, Encodable {
    case unresolved, createNew, matchExisting, ignoreNonTransaction, ignoreIntentional, unknown(String)
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "unresolved": self = .unresolved; case "create_new": self = .createNew; case "match_existing": self = .matchExisting
        case "ignore_non_transaction": self = .ignoreNonTransaction; case "ignore_intentional": self = .ignoreIntentional
        case let value: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
    public var rawValue: String { switch self {
    case .unresolved: "unresolved"; case .createNew: "create_new"; case .matchExisting: "match_existing"
    case .ignoreNonTransaction: "ignore_non_transaction"; case .ignoreIntentional: "ignore_intentional"; case .unknown(let value): value
    } }
    public var displayName: String { switch self {
    case .unresolved: "未解决"; case .createNew: "新建流水"; case .matchExisting: "匹配既有流水"
    case .ignoreNonTransaction: "忽略：非交易"; case .ignoreIntentional: "忽略：有意不导入"; case .unknown(let value): "未知方案（\(value)）"
    } }
    public var isExecutable: Bool { if case .unknown = self { false } else { self != .unresolved } }
}

public struct V15StatementImport: Decodable, Sendable, Equatable, Identifiable {
    public let id: UUID; public let documentSHA256: String; public let byteSize, pageCount: Int; public let mimeType, displayName, currency: String
    public let status: V15StatementImportStatus; public let latestAttemptID: UUID?; public let version: Int
    public let createdAt, updatedAt, confirmedAt, abandonedAt: Date?
    enum CodingKeys: String, CodingKey { case id, status, version, currency; case documentSHA256 = "document_sha256", byteSize = "byte_size", pageCount = "page_count", mimeType = "mime_type", displayName = "display_name", latestAttemptID = "latest_attempt_id", createdAt = "created_at", updatedAt = "updated_at", confirmedAt = "confirmed_at", abandonedAt = "abandoned_at" }
}

public struct V15StatementImportRegistration: Codable, Sendable, Equatable {
    public let documentSHA256: String; public let byteSize, pageCount: Int; public let mimeType, displayName: String
    public init(documentSHA256: String, byteSize: Int, pageCount: Int, displayName: String) { self.documentSHA256 = documentSHA256; self.byteSize = byteSize; self.pageCount = pageCount; self.mimeType = "application/pdf"; self.displayName = displayName }
    enum CodingKeys: String, CodingKey { case documentSHA256 = "document_sha256", byteSize = "byte_size", pageCount = "page_count", mimeType = "mime_type", displayName = "display_name" }
}

public struct V15StatementImportRegistrationResponse: Decodable, Sendable, Equatable { public let duplicate: Bool; public let value: V15StatementImport
    public init(from decoder: Decoder) throws { let c = try V15StatementImport(from: decoder); value = c; duplicate = try decoder.container(keyedBy: Keys.self).decode(Bool.self, forKey: .duplicate) }
    enum Keys: String, CodingKey { case duplicate }
}

public struct V15StatementImportAttempt: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let attemptNumber: Int; public let kind, status: String; public let errorCode: String?; public let startedAt: Date; public let completedAt: Date?
    enum CodingKeys: String, CodingKey { case id, kind, status; case attemptNumber = "attempt_number", errorCode = "error_code", startedAt = "started_at", completedAt = "completed_at" }
}

public struct V15StatementImportVersionRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" } }
public struct V15StatementImportFailureRequest: Codable, Sendable, Equatable { public let expectedVersion: Int; public let errorCode: String; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", errorCode = "error_code" } }
public struct V15StatementImportExtractionStart: Sendable, Equatable { public let attempt: V15StatementImportAttempt; public let nextVersion: Int }

public struct V15StatementBoundingBox: Codable, Sendable, Equatable { public let x, y, width, height: Double }
public struct V15StatementEvidencePage: Codable, Sendable, Equatable { public let pageNumber: Int; public let sourceKind: String; public let evidenceTextMasked: String?; public let boundingBoxes: [V15StatementBoundingBox]
    enum CodingKeys: String, CodingKey { case pageNumber = "page_number", sourceKind = "source_kind", evidenceTextMasked = "evidence_text_masked", boundingBoxes = "bounding_boxes" }
}
public struct V15StatementEvidenceRow: Codable, Sendable, Equatable { public let rowNumber, pageNumber: Int; public let evidenceTextMasked: String; public let boundingBox: V15StatementBoundingBox
    enum CodingKeys: String, CodingKey { case rowNumber = "row_number", pageNumber = "page_number", evidenceTextMasked = "evidence_text_masked", boundingBox = "bounding_box" }
}
public struct V15StatementEvidenceSubmission: Codable, Sendable, Equatable { public let expectedVersion: Int; public let attemptID: UUID; public let pages: [V15StatementEvidencePage]; public let rows: [V15StatementEvidenceRow]
    enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", attemptID = "attempt_id", pages, rows }
}
public struct V15StatementEvidenceResponse: Decodable, Sendable, Equatable { public let attemptID: UUID; public let evidenceSHA256: String; public let rowCount: Int; public let duplicate: Bool; public let batch: V15StatementImport
    enum Keys: String, CodingKey { case attemptID = "attempt_id", evidenceSHA256 = "evidence_sha256", rowCount = "row_count", duplicate }
    public init(from decoder: Decoder) throws { batch = try V15StatementImport(from: decoder); let c = try decoder.container(keyedBy: Keys.self); attemptID = try c.decode(UUID.self, forKey: .attemptID); evidenceSHA256 = try c.decode(String.self, forKey: .evidenceSHA256); rowCount = try c.decode(Int.self, forKey: .rowCount); duplicate = try c.decode(Bool.self, forKey: .duplicate) }
}

public struct V15StatementValidationRunCreate: Codable, Sendable, Equatable { public let expectedBatchVersion: Int; public let providerSnapshotID: UUID; enum CodingKeys: String, CodingKey { case expectedBatchVersion = "expected_batch_version", providerSnapshotID = "provider_snapshot_id" } }
public struct V15StatementReview: Decodable, Sendable, Equatable { public let batchID: UUID; public let batchVersion: Int; public let status: V15StatementImportStatus; public let validationRunID, providerSnapshotID: UUID; public let replay: Bool
    enum CodingKeys: String, CodingKey { case batchID = "batch_id", batchVersion = "batch_version", status, validationRunID = "validation_run_id", providerSnapshotID = "provider_snapshot_id", replay }
}
public struct V15StatementWorkbenchFilter: Codable, Sendable, Equatable {
    public let resolution: V15StatementResolution?; public let candidateKind, checkStatus, evidenceState: String?
    public init(resolution: V15StatementResolution? = nil, candidateKind: String? = nil, checkStatus: String? = nil, evidenceState: String? = nil) { self.resolution = resolution; self.candidateKind = candidateKind; self.checkStatus = checkStatus; self.evidenceState = evidenceState }
    enum CodingKeys: String, CodingKey { case resolution, candidateKind = "candidate_kind", checkStatus = "check_status", evidenceState = "evidence_state" }
}
public struct V15StatementWorkbenchCheck: Codable, Sendable, Equatable { public let checkKind, status: String; public let evidenceRowIDs: [UUID]; enum CodingKeys: String, CodingKey { case checkKind = "check_kind", status, evidenceRowIDs = "evidence_row_ids" } }
public struct V15StatementWorkbenchCandidate: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let candidateKind: String; public let transactionID: UUID?; public let transactionDate: String?; public let amountMinor: V15MinorUnits?; enum CodingKeys: String, CodingKey { case id, candidateKind = "candidate_kind", transactionID = "transaction_id", transactionDate = "transaction_date", amountMinor = "amount_minor" } }
public struct V15StatementDraft: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let resolution: V15StatementResolution; public let matchedTransactionID: UUID?; public let ignoredReason: String?; public let version: Int; enum CodingKeys: String, CodingKey { case id, resolution, version, matchedTransactionID = "matched_transaction_id", ignoredReason = "ignored_reason" } }
public struct V15StatementWorkbenchRow: Codable, Sendable, Equatable, Identifiable { public let id: UUID; public let rowNumber: Int; public let pageNumber: Int?; public let rowVersion: Int; public let sourceKind, evidenceTextMasked: String?; public let boundingBox: V15StatementBoundingBox?; public let draft: V15StatementDraft?; public let candidates: [V15StatementWorkbenchCandidate]; public let finalCreateDraftVersion: Int?; public let isConfirmed: Bool
    enum CodingKeys: String, CodingKey { case id, draft, candidates, boundingBox = "bounding_box", rowNumber = "row_number", pageNumber = "page_number", rowVersion = "row_version", sourceKind = "source_kind", evidenceTextMasked = "evidence_text_masked", finalCreateDraftVersion = "final_create_draft_version", isConfirmed = "is_confirmed" }
}
public struct V15StatementWorkbench: Decodable, Sendable, Equatable { public let batchID: UUID; public let batchVersion: Int; public let status: V15StatementImportStatus; public let reviewAvailable: Bool; public let validationRunID: UUID?; public let checks: [V15StatementWorkbenchCheck]; public let rows: [V15StatementWorkbenchRow]; public let nextCursor: Int?; public let sourceUnavailableCount: Int
    public init(batchID: UUID, batchVersion: Int, status: V15StatementImportStatus, reviewAvailable: Bool, validationRunID: UUID?, checks: [V15StatementWorkbenchCheck], rows: [V15StatementWorkbenchRow], nextCursor: Int?, sourceUnavailableCount: Int) { self.batchID = batchID; self.batchVersion = batchVersion; self.status = status; self.reviewAvailable = reviewAvailable; self.validationRunID = validationRunID; self.checks = checks; self.rows = rows; self.nextCursor = nextCursor; self.sourceUnavailableCount = sourceUnavailableCount }
    enum CodingKeys: String, CodingKey { case batchID = "batch_id", batchVersion = "batch_version", status, reviewAvailable = "review_available", validationRunID = "validation_run_id", checks, rows, nextCursor = "next_cursor", sourceUnavailableCount = "source_unavailable_count" }
}
public struct V15StatementWorkbenchPage: Codable, Sendable, Equatable { public let batchID: UUID; public let pageNumber: Int; public let sourceAvailable: Bool; public let sourceKind, evidenceTextMasked: String?; public let boundingBoxes: [V15StatementBoundingBox]; public let rows: [V15StatementWorkbenchRow]
    enum CodingKeys: String, CodingKey { case batchID = "batch_id", pageNumber = "page_number", sourceAvailable = "source_available", sourceKind = "source_kind", evidenceTextMasked = "evidence_text_masked", boundingBoxes = "bounding_boxes", rows }
}
public struct V15StatementDraftResolutionPut: Codable, Sendable, Equatable { public let expectedBatchVersion, expectedRowVersion, expectedResolutionVersion: Int; public let resolution: V15StatementResolution; public let matchedTransactionID: UUID?; public let ignoredReason: String?
    enum CodingKeys: String, CodingKey { case expectedBatchVersion = "expected_batch_version", expectedRowVersion = "expected_row_version", expectedResolutionVersion = "expected_resolution_version", resolution, matchedTransactionID = "matched_transaction_id", ignoredReason = "ignored_reason" }
}
public struct V15StatementFinalCreateDraftPut: Codable, Sendable, Equatable { public let expectedVersion: Int; public let transaction: V15TransactionCreateRequest; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version", transaction } }
public struct V15StatementFinalCreateDraft: Codable, Sendable, Equatable { public let id, statementImportRowID, draftResolutionID: UUID; public let transaction: V15TransactionCreateRequest; public let version: Int; enum CodingKeys: String, CodingKey { case id, transaction, version, statementImportRowID = "statement_import_row_id", draftResolutionID = "draft_resolution_id" } }

public struct V15StatementConfirmRow: Codable, Sendable, Equatable { public let rowID: UUID; public let expectedRowVersion, expectedDraftVersion: Int; public let expectedFinalCreateDraftVersion: Int?; enum CodingKeys: String, CodingKey { case rowID = "row_id", expectedRowVersion = "expected_row_version", expectedDraftVersion = "expected_draft_version", expectedFinalCreateDraftVersion = "expected_final_create_draft_version" } }
public struct V15StatementConfirmRequest: Codable, Sendable, Equatable { public let expectedBatchVersion: Int; public let rows: [V15StatementConfirmRow]; enum CodingKeys: String, CodingKey { case expectedBatchVersion = "expected_batch_version", rows } }
public struct V15StatementPreviewCounts: Codable, Sendable, Equatable { public let selected, createNew, matchExisting, ignoreNonTransaction, ignoreIntentional, unresolved, batchUnresolved: Int; enum CodingKeys: String, CodingKey { case selected, unresolved, createNew = "create_new", matchExisting = "match_existing", ignoreNonTransaction = "ignore_non_transaction", ignoreIntentional = "ignore_intentional", batchUnresolved = "batch_unresolved" } }
public struct V15StatementPreviewAmounts: Codable, Sendable, Equatable { public let knownCreateMinor, knownMatchMinor, knownTotalMinor: V15MinorUnits; public let unknownSelectedCount: Int; enum CodingKeys: String, CodingKey { case knownCreateMinor = "known_create_minor", knownMatchMinor = "known_match_minor", knownTotalMinor = "known_total_minor", unknownSelectedCount = "unknown_selected_count" } }
public struct V15StatementConfirmationPreview: Decodable, Sendable, Equatable { public let batchID: UUID; public let batchVersion: Int; public let status: V15StatementImportStatus; public let counts: V15StatementPreviewCounts; public let amounts: V15StatementPreviewAmounts; public let warnings: [String]; public let request: V15StatementConfirmRequest; enum CodingKeys: String, CodingKey { case batchID = "batch_id", batchVersion = "batch_version", status, counts, amounts, warnings, request } }
public struct V15StatementConfirmationPreviewRequest: Codable, Sendable, Equatable { public let rowIDs: [UUID]; enum CodingKeys: String, CodingKey { case rowIDs = "row_ids" } }
public struct V15StatementConfirmationRowReceipt: Codable, Sendable, Equatable { public let rowID: UUID; public let resolution: String; public let outcome: String; public let transactionID: UUID?; enum CodingKeys: String, CodingKey { case rowID = "row_id", resolution, outcome, transactionID = "transaction_id" } }
public struct V15StatementConfirmationReceipt: Codable, Sendable, Equatable { public let operationID, batchID: UUID; public let batchVersion: Int; public let status: String; public let confirmedRowIDs: [UUID]; public let rowResults: [V15StatementConfirmationRowReceipt]; public let createdCount, matchedCount, skippedCount: Int; public let resultDetailStatus: String; public let replay: Bool
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", batchID = "batch_id", batchVersion = "batch_version", status, confirmedRowIDs = "confirmed_row_ids", rowResults = "row_results", createdCount = "created_count", matchedCount = "matched_count", skippedCount = "skipped_count", resultDetailStatus = "result_detail_status", replay }
}
