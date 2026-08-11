import Foundation

public struct AIQualityMetricsResponse: Codable, Sendable, Equatable {
  public let rows: [AIQualityMetricsRow]
}

public struct AIQualityMetricsRow: Codable, Sendable, Equatable, Identifiable {
  public let source: AIProposalSource
  public let provider: String?
  public let model: String?
  public let promptVersion: String?
  public let transactionKind: String?
  public let amountBand: String
  public let total: Int
  public let parseSucceeded: Int
  public let historicalUnavailable: Int
  public let confirmUnchanged: Int
  public let confirmEdited: Int
  public let ignored: Int
  public let executeFailed: Int
  public let automaticExecute: Int
  public let manualExecute: Int
  public let undone: Int
  public let providerRetry: Int
  public let finalFailure: Int
  public let pending: Int
  public let terminalOutcomes: Int

  public var id: String { "\(source.rawValue)|\(model ?? "legacy")|\(transactionKind ?? "unknown")|\(amountBand)" }
  enum CodingKeys: String, CodingKey {
    case source, provider, model, total, pending
    case promptVersion = "prompt_version"; case transactionKind = "transaction_kind"
    case amountBand = "amount_band"; case parseSucceeded = "parse_succeeded"
    case historicalUnavailable = "historical_unavailable"
    case confirmUnchanged = "confirm_unchanged"; case confirmEdited = "confirm_edited"
    case ignored; case executeFailed = "execute_failed"; case automaticExecute = "automatic_execute"
    case manualExecute = "manual_execute"; case undone; case providerRetry = "provider_retry"
    case finalFailure = "final_failure"; case terminalOutcomes = "terminal_outcomes"
  }
  public var denominatorConserved: Bool { total == pending + terminalOutcomes }
}

public enum AILearningRuleKind: String, Codable, Sendable {
  case merchantCategory = "merchant_category"
  case titleAccount = "title_account"
  case categoryAlias = "category_alias"
  public var title: String {
    switch self { case .merchantCategory: "商户→分类"; case .titleAccount: "标题→账户"; case .categoryAlias: "分类别名" }
  }
}

public struct AILearningRuleDTO: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let ruleKind: AILearningRuleKind
  public let normalizedKey: String
  public let source: AIProposalSource?
  public let categoryID: UUID?
  public let accountID: UUID?
  public let evidenceCount: Int
  public let enabled: Bool
  public let revokedAt: Date?
  enum CodingKeys: String, CodingKey {
    case id, source, enabled
    case ruleKind = "rule_kind"; case normalizedKey = "normalized_key"
    case categoryID = "category_id"; case accountID = "account_id"
    case evidenceCount = "evidence_count"; case revokedAt = "revoked_at"
  }
}
