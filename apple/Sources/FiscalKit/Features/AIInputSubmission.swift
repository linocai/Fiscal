import CryptoKit
import Foundation

public protocol AIInputCreating: Sendable {
  func create(source: AIProposalSource, text: String, idempotencyKey: UUID) async throws
    -> AIProposalDTO
}

extension RemoteAIProposalRepository: AIInputCreating {}

public protocol AIInputRetryKeyStoring: Sendable {
  func key(for fingerprint: String) async -> UUID
  func clear(fingerprint: String) async
}

public actor PersistentAIInputRetryKeyStore: AIInputRetryKeyStoring {
  private struct Entry: Codable {
    let key: UUID
    let createdAt: Date
  }

  private let defaults: UserDefaults
  private let prefix = "p9.ai-input.retry-key."
  private let retryWindow: TimeInterval

  public init(defaults: UserDefaults = .standard, retryWindow: TimeInterval = 10 * 60) {
    self.defaults = defaults
    self.retryWindow = retryWindow
  }

  public func key(for fingerprint: String) -> UUID {
    let storageKey = prefix + fingerprint
    if let data = defaults.data(forKey: storageKey),
      let entry = try? JSONDecoder().decode(Entry.self, from: data),
      Date().timeIntervalSince(entry.createdAt) < retryWindow
    {
      return entry.key
    }
    let key = UUID()
    defaults.set(try? JSONEncoder().encode(Entry(key: key, createdAt: Date())), forKey: storageKey)
    return key
  }

  public func clear(fingerprint: String) { defaults.removeObject(forKey: prefix + fingerprint) }
}

public actor AIInputSubmissionService {
  private let repository: any AIInputCreating
  private let retryKeys: any AIInputRetryKeyStoring

  public init(
    repository: any AIInputCreating,
    retryKeys: any AIInputRetryKeyStoring = PersistentAIInputRetryKeyStore()
  ) {
    self.repository = repository
    self.retryKeys = retryKeys
  }

  public func submit(source: AIProposalSource, text rawText: String) async throws -> AIProposalDTO {
    let text = Self.normalized(rawText)
    guard !text.isEmpty else { throw AIInputError.emptyText }
    guard text.count <= 2_000 else { throw AIInputError.textTooLong }

    let fingerprint = Self.fingerprint(source: source, text: text)
    let key = await retryKeys.key(for: fingerprint)
    do {
      let proposal = try await repository.create(
        source: source, text: text, idempotencyKey: key)
      await retryKeys.clear(fingerprint: fingerprint)
      return proposal
    } catch {
      if !Self.shouldPreserveRetryKey(after: error) {
        await retryKeys.clear(fingerprint: fingerprint)
      }
      throw error
    }
  }

  public static func normalized(_ text: String) -> String {
    text
      .split(whereSeparator: \.isNewline)
      .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  public static func fingerprint(source: AIProposalSource, text: String) -> String {
    let digest = SHA256.hash(data: Data("\(source.rawValue)\u{0}\(text)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  public static func shouldPreserveRetryKey(after error: Error) -> Bool {
    guard let api = error as? FiscalAPIError else { return false }
    switch api {
    case .transport, .invalidResponse: return true
    case .domain(_, let detail):
      return [
        "ai_provider_not_configured", "ai_provider_unavailable",
        "ai_provider_invalid_response", "ai_processing_cancelled",
      ].contains(detail.code)
    case .unauthorized: return false
    }
  }
}

public enum AIInputError: Error, LocalizedError, Sendable, Equatable {
  case emptyText
  case textTooLong

  public var errorDescription: String? {
    switch self {
    case .emptyText: "没有识别到可用于记账的文字。"
    case .textTooLong: "识别内容过长，请裁剪截图后重试。"
    }
  }
}

public enum AIInputFeedback {
  public static func message(for error: Error) -> String {
    if let error = error as? AIInputError { return error.localizedDescription }
    if let error = error as? OCRInputError { return error.localizedDescription }
    if let error = error as? FiscalAPIError {
      switch error {
      case .domain(_, let detail) where detail.code == "ai_provider_not_configured":
        return "AI 服务尚未配置，请先在 VPS 配置模型。"
      case .domain(_, let detail) where detail.code == "ai_source_disabled":
        return "这个快捷录入来源尚未启用，请先在 Fiscal 设置中开启。"
      case .domain(_, let detail) where detail.code == "ai_processing_cancelled":
        return "识别被系统中断，请用同一次输入重试；Fiscal 不会重复记账。"
      default: return error.displayMessage
      }
    }
    return "本次记账没有完成，请稍后重试。"
  }

  public static func success(for proposal: AIProposalDTO) -> String {
    switch proposal.status {
    case .executed: "已自动记账：\(proposal.title ?? "新流水")。"
    case .pending: "已加入 AI 待确认，请在 Fiscal 中检查。"
    case .processing: "已收到，Fiscal 正在识别。"
    case .failed: "识别失败，已保留在 AI 队列中。"
    case .ignored: "该提案已忽略。"
    case .undone: "该提案对应的流水已撤销。"
    }
  }
}
