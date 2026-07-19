import Foundation

public enum AIProposalStatus: String, Codable, Sendable, CaseIterable, Identifiable {
  case processing, pending, executed, ignored, failed, undone
  public var id: Self { self }
  public var title: String {
    switch self {
    case .processing: "识别中"
    case .pending: "待确认"
    case .executed: "已记账"
    case .ignored: "已忽略"
    case .failed: "识别失败"
    case .undone: "已撤销"
    }
  }
}

public enum AIProposalSource: String, Codable, Sendable {
  case text
  case ocr
  case shortcutText = "shortcut_text"
  public var title: String {
    switch self {
    case .text: "文本"
    case .ocr: "截图 OCR"
    case .shortcutText: "快捷指令文本"
    }
  }
}

public enum AIProposalTarget: String, Codable, Sendable {
  case transaction
  case cashFlow = "cash_flow"
  public var title: String { self == .cashFlow ? "未来现金流" : "正式流水" }
  public var executeTitle: String { self == .cashFlow ? "创建现金流" : "确认记账" }
  public var executedTitle: String { self == .cashFlow ? "已创建现金流" : "已记账" }
}

public struct AIProposalDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let source: AIProposalSource
  public let text: String
  public let contentFingerprint: String
  public let provider: String?
  public let model: String?
  public let target: AIProposalTarget
  public let status: AIProposalStatus
  public let kind: TransactionKind?
  public let amountMinor: Int64?
  public let occurredAt: Date?
  public let title: String?
  public let note: String?
  public let accountID: UUID?
  public let categoryID: UUID?
  public let destinationAccountID: UUID?
  public let creditCycleID: UUID?
  public let fieldConfidences: [String: Int]
  public let overallConfidenceBps: Int?
  public let missingFields: [String]
  public let reasonCodes: [String]
  public let explanation: String?
  public let errorCode: String?
  public let errorMessage: String?
  public let transactionID: UUID?
  public let transactionVersion: Int?
  public let cashFlowItemID: UUID?
  public let cashFlowItemVersion: Int?
  public let version: Int
  public let createdAt: Date
  public let updatedAt: Date
  public let executedAt: Date?
  public let ignoredAt: Date?
  public let undoneAt: Date?

  enum CodingKeys: String, CodingKey {
    case id, source, text, status, kind, title, note, version, explanation, provider, model, target
    case contentFingerprint = "content_fingerprint"
    case amountMinor = "amount_minor"
    case occurredAt = "occurred_at"
    case accountID = "account_id"
    case categoryID = "category_id"
    case destinationAccountID = "destination_account_id"; case creditCycleID = "credit_cycle_id"
    case fieldConfidences = "field_confidences"
    case overallConfidenceBps = "overall_confidence_bps"
    case missingFields = "missing_fields"
    case reasonCodes = "reason_codes"
    case errorCode = "error_code"
    case errorMessage = "error_message"
    case transactionID = "transaction_id"
    case transactionVersion = "transaction_version"
    case cashFlowItemID = "cash_flow_item_id"
    case cashFlowItemVersion = "cash_flow_item_version"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case executedAt = "executed_at"
    case ignoredAt = "ignored_at"
    case undoneAt = "undone_at"
  }

  public var confidenceTitle: String {
    guard let value = overallConfidenceBps else { return "—" }
    return "\(value / 100)%"
  }
  public var reviewWarnings: [String] {
    let labels = [
      "kind": "类型", "amount_minor": "金额", "occurred_at": "发生时间", "title": "标题",
      "note": "备注", "account_id": "账户", "category_id": "分类",
      "destination_account_id": "目标账户", "credit_cycle_id": "信用账期",
      "forbidden_kind": "类型不能由 AI 生成", "unknown_account": "账户已失效",
      "unknown_category": "分类已失效", "unknown_destination_account": "目标账户已失效",
      "account_kind_mismatch": "账户类型不匹配", "category_direction_mismatch": "分类方向不匹配",
      "destination_kind_mismatch": "目标账户类型不匹配",
      "ledger_validation_failed": "未通过账本安全校验", "manual_confirmation_required": "需要人工确认",
      "user_edited": "已由你修改", "future_cash_flow_requires_confirmation": "未来计划必须人工确认",
    ]
    let missing = missingFields.map { "缺少\(labels[$0] ?? $0)" }
    return missing + reasonCodes.map { labels[$0] ?? "需要人工检查" }
  }
  public var canReview: Bool { status == .pending }
  /// Fields the server's execute validation will reject as missing for a ledger proposal.
  /// Mirrors `_draft`/`_create` requirements so the confirm button can be gated instead of
  /// letting a doomed request 4xx. Cash-flow proposals follow different rules and never block.
  public var executionBlockers: [String] {
    guard target == .transaction else { return [] }
    var blockers: [String] = []
    if kind == nil { blockers.append("类型") }
    if !(amountMinor.map { $0 > 0 } ?? false) { blockers.append("金额") }
    if occurredAt == nil { blockers.append("发生时间") }
    if (title ?? "").isEmpty { blockers.append("标题") }
    if accountID == nil { blockers.append("账户") }
    if kind == .transfer || kind == .repayment, destinationAccountID == nil {
      blockers.append("目标账户")
    }
    return blockers
  }
  public var draft: TransactionDraft {
    var value = TransactionDraft()
    value.kind = kind ?? .expense
    value.amountMinor = amountMinor ?? 0
    value.occurredAt = occurredAt ?? Date()
    value.title = title ?? ""
    value.note = note ?? ""
    value.accountID = accountID
    value.categoryID = categoryID
    value.destinationAccountID = destinationAccountID
    value.creditCycleID = creditCycleID
    return value
  }
}

public struct AIProposalPage: Codable, Sendable, Equatable {
  public let items: [AIProposalDTO]
  public let nextCursor: String?
  public let pendingCount: Int
  enum CodingKeys: String, CodingKey {
    case items
    case nextCursor = "next_cursor"
    case pendingCount = "pending_count"
  }
  public init(items: [AIProposalDTO], nextCursor: String?, pendingCount: Int) {
    self.items = items; self.nextCursor = nextCursor; self.pendingCount = pendingCount
  }
}

public struct AIProposalCreateRequest: Codable, Sendable, Equatable {
  public let source: AIProposalSource
  public let text: String
  public init(text: String) { source = .text; self.text = text }
  public init(source: AIProposalSource, text: String) { self.source = source; self.text = text }
}

public struct AIProposalReplacementRequest: Encodable, Sendable {
  public let draft: TransactionDraft
  public let expectedVersion: Int
  public init(draft: TransactionDraft, expectedVersion: Int) {
    self.draft = draft; self.expectedVersion = expectedVersion
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(draft, forKey: .draft)
    try container.encode(expectedVersion, forKey: .expectedVersion)
  }
  enum CodingKeys: String, CodingKey { case draft; case expectedVersion = "expected_version" }
}

public struct AIProposalActionResponse: Codable, Sendable, Equatable {
  public let proposal: AIProposalDTO
  public let transaction: TransactionDTO?
  public let cashFlowItem: FutureCashFlowItem?
  enum CodingKeys: String, CodingKey { case proposal, transaction; case cashFlowItem = "cash_flow_item" }
  public init(
    proposal: AIProposalDTO, transaction: TransactionDTO?, cashFlowItem: FutureCashFlowItem? = nil
  ) {
    self.proposal = proposal; self.transaction = transaction; self.cashFlowItem = cashFlowItem
  }
}

public struct AIProposalUndoRequest: Codable, Sendable, Equatable {
  public let expectedVersion: Int
  public let expectedTransactionVersion: Int?
  enum CodingKeys: String, CodingKey {
    case expectedVersion = "expected_version"
    case expectedTransactionVersion = "expected_transaction_version"
  }
  public init(expectedVersion: Int, expectedTransactionVersion: Int?) {
    self.expectedVersion = expectedVersion
    self.expectedTransactionVersion = expectedTransactionVersion
  }
}
