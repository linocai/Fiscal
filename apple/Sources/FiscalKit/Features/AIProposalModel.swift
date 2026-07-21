import Foundation
import Observation

public enum AIProposalPhase: Sendable, Equatable { case idle, loading, loaded, empty, failed }

@MainActor
@Observable
public final class AIProposalModel {
  public private(set) var proposals: [AIProposalDTO] = []
  public private(set) var pendingCount = 0
  public private(set) var phase: AIProposalPhase = .idle
  public private(set) var message: String?
  public private(set) var refreshMessage: String?
  public private(set) var nextCursor: String?
  public private(set) var isLoadingMore = false
  public private(set) var isMutating = false
  public private(set) var conflictDetected = false
  public private(set) var shouldRotateCreateKeyAfterFailure = false
  public var selectedID: UUID?
  public private(set) var statusFilter: AIProposalStatus? = .pending

  private let repository: any AIProposalRepository
  private let transactions: TransactionsModel?
  private let reporting: ReportingInvalidationCoordinator?
  private let cashFlow: FutureCashFlowModel?
  private var generation = 0
  private var ledgerRefreshTask: Task<Void, Never>?
  private var ledgerRefreshPending = false

  public init(
    repository: any AIProposalRepository, transactions: TransactionsModel? = nil,
    reporting: ReportingInvalidationCoordinator? = nil, cashFlow: FutureCashFlowModel? = nil
  ) {
    self.repository = repository; self.transactions = transactions; self.reporting = reporting
    self.cashFlow = cashFlow
  }
  public var selected: AIProposalDTO? { proposals.first { $0.id == selectedID } }

  public func selectStatus(_ status: AIProposalStatus) async {
    guard status == .pending || status == .failed, statusFilter != status else { return }
    statusFilter = status
    selectedID = nil
    proposals = []
    nextCursor = nil
    phase = .loading
    await load()
  }

  public func load() async {
    generation += 1; let current = generation; let filter = statusFilter
    let preservesData = !proposals.isEmpty
    if !preservesData { phase = .loading }
    message = nil; refreshMessage = nil; conflictDetected = false
    do {
      let page = try await repository.list(status: filter, cursor: nil, limit: 30)
      guard current == generation, filter == statusFilter else { return }
      proposals = page.items; nextCursor = page.nextCursor; pendingCount = page.pendingCount
      if let selectedID, !proposals.contains(where: { $0.id == selectedID }) {
        self.selectedID = proposals.first?.id
      } else if selectedID == nil { selectedID = proposals.first?.id }
      phase = proposals.isEmpty ? .empty : .loaded
    } catch is CancellationError { if current == generation, !preservesData { phase = .idle } }
    catch { guard current == generation else { return }; apply(error, preserving: preservesData) }
  }

  public func loadMore() async {
    guard let cursor = nextCursor, !isLoadingMore else { return }
    let current = generation; let filter = statusFilter; let knownCursor = nextCursor
    isLoadingMore = true; defer { isLoadingMore = false }
    do {
      let page = try await repository.list(status: filter, cursor: cursor, limit: 30)
      guard current == generation, filter == statusFilter, knownCursor == nextCursor else { return }
      let known = Set(proposals.map(\.id))
      proposals += page.items.filter { !known.contains($0.id) }
      nextCursor = page.nextCursor; pendingCount = page.pendingCount
    } catch is CancellationError {
    } catch { if current == generation { refreshMessage = display(error) } }
  }

  public func create(text: String, idempotencyKey: UUID) async -> Bool {
    await create(source: .text, text: text, idempotencyKey: idempotencyKey)
  }

  public func create(
    source: AIProposalSource, text: String, idempotencyKey: UUID
  ) async -> Bool {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 2_000 else {
      message = "请输入 1–2,000 个字符的记账描述。"; return false
    }
    guard !isMutating else { return false }
    beginMutation(); let current = generation
    shouldRotateCreateKeyAfterFailure = false; isMutating = true; defer { isMutating = false }
    do {
      let proposal = try await repository.create(
        source: source, text: normalized, idempotencyKey: idempotencyKey)
      guard current == generation else { return false }
      selectedID = proposal.id; await load(); return true
    } catch {
      shouldRotateCreateKeyAfterFailure = !AIInputSubmissionService.shouldPreserveRetryKey(
        after: error)
      guard current == generation else { return false }; apply(error, preserving: !proposals.isEmpty)
      return false
    }
  }

  public func update(_ proposal: AIProposalDTO, draft: TransactionDraft) async -> Bool {
    guard TransactionEditorModel.validate(draft) == nil else {
      message = TransactionEditorModel.validate(draft); return false
    }
    return await mutate(proposal) {
      let updated = try await self.repository.update(
        id: proposal.id,
        request: .init(draft: draft, expectedVersion: proposal.version))
      self.replace(updated)
    }
  }

  public func execute(_ proposal: AIProposalDTO) async -> Bool {
    return await mutate(proposal, refreshLedger: true) {
      let response = try await self.repository.action(
        id: proposal.id, action: "execute", expectedVersion: proposal.version)
      self.replace(response.proposal)
    }
  }
  public func ignore(_ proposal: AIProposalDTO) async -> Bool {
    await mutate(proposal) {
      let response = try await self.repository.action(
        id: proposal.id, action: "ignore", expectedVersion: proposal.version)
      self.replace(response.proposal)
    }
  }
  public func retry(_ proposal: AIProposalDTO) async -> Bool {
    await mutate(proposal) {
      let response = try await self.repository.action(
        id: proposal.id, action: "retry", expectedVersion: proposal.version)
      self.replace(response.proposal)
    }
  }
  public func undo(_ proposal: AIProposalDTO) async -> Bool {
    let transactionVersion = proposal.transactionVersion
    guard proposal.target == .cashFlow || transactionVersion != nil else {
      message = "缺少流水版本，无法安全撤销。"; return false
    }
    return await mutate(proposal, refreshLedger: true) {
      let response = try await self.repository.undo(
        id: proposal.id, expectedVersion: proposal.version,
        expectedTransactionVersion: transactionVersion)
      self.replace(response.proposal)
    }
  }

  public func clearMessage() { message = nil; refreshMessage = nil }
  public func clearConflict() { conflictDetected = false }

  private func mutate(
    _ proposal: AIProposalDTO, refreshLedger: Bool = false,
    operation: () async throws -> Void
  ) async -> Bool {
    guard !isMutating else { return false }
    beginMutation(); let current = generation; isMutating = true; defer { isMutating = false }
    do {
      try await operation(); guard current == generation else { return false }
      await load()
      // Ledger/report refreshes run coalesced in the background: holding isMutating through
      // them kept the confirm button dead for seconds per proposal and turned consecutive
      // confirms into a request storm against the single-worker VPS.
      if refreshLedger { scheduleLedgerRefresh() }
      return true
    } catch {
      guard current == generation else { return false }; apply(error, preserving: !proposals.isEmpty)
      return false
    }
  }

  /// One background runner drains the pending flag, so any number of rapid confirms ends in at
  /// most one trailing full refresh instead of one storm each.
  private func scheduleLedgerRefresh() {
    ledgerRefreshPending = true
    guard ledgerRefreshTask == nil else { return }
    ledgerRefreshTask = Task { [weak self] in
      while let self, self.ledgerRefreshPending {
        self.ledgerRefreshPending = false
        async let transactionRefresh: Void = self.transactions?.load() ?? ()
        async let reportRefresh: Void = self.reporting?.refresh() ?? ()
        async let cashFlowRefresh: Void = self.cashFlow?.load() ?? ()
        _ = await (transactionRefresh, reportRefresh, cashFlowRefresh)
      }
      self?.ledgerRefreshTask = nil
    }
  }
  private func beginMutation() {
    generation += 1; message = nil; refreshMessage = nil; conflictDetected = false
  }
  private func replace(_ proposal: AIProposalDTO) {
    if let index = proposals.firstIndex(where: { $0.id == proposal.id }) { proposals[index] = proposal }
  }
  private func apply(_ error: Error, preserving: Bool) {
    let text = display(error); message = text
    if let api = error as? FiscalAPIError, case .domain(_, let detail) = api,
      detail.code == "resource_version_conflict"
    { conflictDetected = true }
    if preserving { refreshMessage = text; phase = .loaded } else { phase = .failed }
  }
  private func display(_ error: Error) -> String {
    (error as? FiscalAPIError)?.displayMessage ?? "AI 提案暂时无法读取。"
  }
}
