import Foundation
import Observation

@MainActor
@Observable
public final class ReimbursementModel {
  public private(set) var claims: [ReimbursementClaimDTO] = []
  public private(set) var selectedClaim: ReimbursementClaimDTO?
  public private(set) var receiptHistory: [ReimbursementReceiptDTO] = []
  public private(set) var expenseOptions: [ReimbursementExpenseOption] = []
  public private(set) var summary: ReimbursementSummary?
  public private(set) var claimPreview: ReimbursementClaimPreview?
  public private(set) var receiptPreview: ReimbursementReceiptPreview?
  public private(set) var cancelPreview: ReimbursementCancelPreview?
  public private(set) var phase: MasterDataPhase = .idle
  public private(set) var message: String?
  public private(set) var refreshMessage: String?
  public private(set) var nextCursor: String?
  public private(set) var receiptNextCursor: String?
  public private(set) var isMutating = false
  public private(set) var loadingMoreClaims = false
  public private(set) var loadingMoreReceipts = false
  public private(set) var conflictDetected = false
  public var statusFilter: ReimbursementClaimStatus?
  public var includeArchived = false

  private let repository: any ReimbursementRepository
  private let transactions: TransactionsModel?
  private let accounts: AccountsModel?
  private var generation = 0
  private var previewedClaimRequest: ReimbursementClaimReplacementRequest?
  private var claimPreviewGeneration = 0
  private var previewedReceiptRequest: ReimbursementReceiptRequest?
  private var previewedReceiptReplacement: ReimbursementReceiptReplacementRequest?

  public init(
    repository: any ReimbursementRepository, transactions: TransactionsModel? = nil,
    accounts: AccountsModel? = nil
  ) {
    self.repository = repository
    self.transactions = transactions
    self.accounts = accounts
  }

  public func load() async {
    generation += 1
    let current = generation
    phase = .loading
    message = nil
    refreshMessage = nil
    conflictDetected = false
    do {
      async let page = repository.list(
        status: statusFilter, includeArchived: includeArchived, cursor: nil, limit: 30)
      async let totals = repository.summary(dateFrom: nil, dateTo: nil)
      let (loaded, loadedSummary) = try await (page, totals)
      guard current == generation else { return }
      claims = loaded.items
      nextCursor = loaded.nextCursor
      summary = loadedSummary
      phase = claims.isEmpty ? .empty : .loaded
    } catch is CancellationError { if current == generation { phase = .idle } } catch {
      guard current == generation else { return }
      apply(error, preserving: false)
    }
  }

  public func loadClaim(_ id: UUID) async {
    generation += 1
    let current = generation
    phase = .loading
    message = nil
    refreshMessage = nil
    conflictDetected = false
    receiptHistory = []
    receiptNextCursor = nil
    do {
      async let detail = repository.get(id: id)
      async let receipts = repository.receipts(claimID: id, cursor: nil, limit: 30)
      let (claim, page) = try await (detail, receipts)
      guard current == generation else { return }
      selectedClaim = claim
      receiptHistory = page.items
      receiptNextCursor = page.nextCursor
      phase = .loaded
    } catch is CancellationError { if current == generation { phase = .idle } } catch {
      guard current == generation else { return }
      apply(error, preserving: false)
    }
  }

  public func loadMore() async {
    guard let cursor = nextCursor, !loadingMoreClaims else { return }
    let current = generation
    let filter = statusFilter
    let archived = includeArchived
    loadingMoreClaims = true
    defer { loadingMoreClaims = false }
    do {
      let page = try await repository.list(
        status: filter, includeArchived: archived, cursor: cursor, limit: 30)
      guard current == generation, filter == statusFilter, archived == includeArchived else {
        return
      }
      let known = Set(claims.map(\.id))
      claims += page.items.filter { !known.contains($0.id) }
      nextCursor = page.nextCursor
    } catch { if current == generation { refreshMessage = display(error) } }
  }
  public func loadMoreReceipts(claimID: UUID) async {
    guard selectedClaim?.id == claimID, let cursor = receiptNextCursor, !loadingMoreReceipts else {
      return
    }
    let current = generation
    loadingMoreReceipts = true
    defer { loadingMoreReceipts = false }
    do {
      let page = try await repository.receipts(claimID: claimID, cursor: cursor, limit: 30)
      guard current == generation, selectedClaim?.id == claimID else { return }
      let known = Set(receiptHistory.map(\.id))
      receiptHistory += page.items.filter { !known.contains($0.id) }
      receiptNextCursor = page.nextCursor
    } catch { if current == generation { refreshMessage = display(error) } }
  }
  public func loadExpenseOptions(search: String? = nil) async {
    do { expenseOptions = try await repository.expenseOptions(search: search) } catch {
      apply(error, preserving: true)
    }
  }

  public func create(_ request: ReimbursementClaimCreateRequest, idempotencyKey: UUID = UUID())
    async -> ReimbursementClaimDTO?
  {
    guard
      let claim: ReimbursementClaimDTO = await mutate({
        try await repository.create(request, idempotencyKey: idempotencyKey)
      })
    else { return nil }
    selectedClaim = claim
    await refreshAll(claimID: claim.id)
    return claim
  }
  public func preview(_ request: ReimbursementClaimReplacementRequest) async -> Bool {
    guard let id = selectedClaim?.id else { return false }
    claimPreviewGeneration += 1
    let current = claimPreviewGeneration
    let version = selectedClaim?.version
    claimPreview = nil
    message = nil
    do {
      let preview = try await repository.preview(id: id, request: request)
      guard current == claimPreviewGeneration, selectedClaim?.id == id,
        selectedClaim?.version == version
      else { return false }
      claimPreview = preview
      previewedClaimRequest = request
      return true
    } catch {
      guard current == claimPreviewGeneration else { return false }
      apply(error, preserving: true)
      return false
    }
  }
  public func update(_ request: ReimbursementClaimReplacementRequest) async -> Bool {
    guard let id = selectedClaim?.id, previewedClaimRequest == request, claimPreview != nil else {
      message = "输入已变化，请重新预览。"
      claimPreview = nil
      previewedClaimRequest = nil
      return false
    }
    guard
      let claim: ReimbursementClaimDTO = await mutate({
        try await repository.update(id: id, request: request)
      })
    else { return false }
    selectedClaim = claim
    clearPreviews()
    await refreshAll(claimID: id)
    return true
  }

  public func lifecycle(_ action: String) async -> Bool {
    guard let claim = selectedClaim else { return false }
    guard
      let result: ReimbursementClaimDTO = await mutate({
        try await repository.lifecycle(id: claim.id, action: action, version: claim.version)
      })
    else { return false }
    selectedClaim = result
    await refreshAll(claimID: claim.id)
    return true
  }
  public func previewCancellation() async -> Bool {
    guard let claim = selectedClaim else { return false }
    do {
      let preview = try await repository.cancelPreview(id: claim.id, version: claim.version)
      guard selectedClaim?.id == claim.id, selectedClaim?.version == claim.version else {
        cancelPreview = nil
        message = "报销单已变化，请重新预览取消操作。"
        return false
      }
      cancelPreview = preview
      return true
    } catch {
      apply(error, preserving: true)
      return false
    }
  }

  public func confirmCancel() async -> Bool {
    guard let claim = selectedClaim, let preview = cancelPreview,
      claim.id == preview.current.id, claim.version == preview.current.version
    else {
      cancelPreview = nil
      message = "报销单已变化，请重新预览取消操作。"
      return false
    }
    guard
      let result: ReimbursementClaimDTO = await mutate({
        try await repository.lifecycle(
          id: preview.current.id, action: "cancel-outstanding", version: preview.current.version)
      })
    else { return false }
    selectedClaim = result
    clearPreviews()
    await refreshAll(claimID: preview.current.id)
    return true
  }

  public func previewReceipt(_ request: ReimbursementReceiptRequest) async -> Bool {
    guard let claim = selectedClaim else { return false }
    receiptPreview = nil
    message = nil
    do {
      receiptPreview = try await repository.receiptPreview(
        id: nil, claimID: claim.id, create: request, replace: nil)
      previewedReceiptRequest = request
      return true
    } catch {
      apply(error, preserving: true)
      return false
    }
  }
  public func createReceipt(_ request: ReimbursementReceiptRequest, idempotencyKey: UUID = UUID())
    async -> Bool
  {
    guard let claim = selectedClaim, previewedReceiptRequest == request, receiptPreview != nil
    else {
      message = "输入已变化，请重新预览。"
      receiptPreview = nil
      previewedReceiptRequest = nil
      return false
    }
    guard
      let _: ReimbursementReceiptDTO = await mutate({
        try await repository.createReceipt(
          claimID: claim.id, request: request, idempotencyKey: idempotencyKey)
      })
    else { return false }
    clearPreviews()
    await refreshAll(claimID: claim.id)
    return true
  }
  public func previewReceiptReplacement(
    _ receipt: ReimbursementReceiptDTO, request: ReimbursementReceiptReplacementRequest
  ) async -> Bool {
    guard let claim = selectedClaim else { return false }
    receiptPreview = nil
    message = nil
    do {
      receiptPreview = try await repository.receiptPreview(
        id: receipt.id, claimID: claim.id, create: nil, replace: request)
      previewedReceiptReplacement = request
      return true
    } catch {
      apply(error, preserving: true)
      return false
    }
  }
  public func updateReceipt(
    _ receipt: ReimbursementReceiptDTO, request: ReimbursementReceiptReplacementRequest
  ) async -> Bool {
    guard let claim = selectedClaim, previewedReceiptReplacement == request, receiptPreview != nil
    else {
      message = "输入已变化，请重新预览。"
      receiptPreview = nil
      previewedReceiptReplacement = nil
      return false
    }
    guard
      let _: ReimbursementReceiptDTO = await mutate({
        try await repository.updateReceipt(id: receipt.id, request: request)
      })
    else { return false }
    clearPreviews()
    await refreshAll(claimID: claim.id)
    return true
  }
  public func receiptLifecycle(_ receipt: ReimbursementReceiptDTO, action: String) async -> Bool {
    guard let claim = selectedClaim else { return false }
    let request = ReimbursementReceiptVersionRequest(
      expectedClaimVersion: claim.version, expectedReceiptVersion: receipt.version)
    guard
      let _: ReimbursementReceiptDTO = await mutate({
        try await repository.receiptLifecycle(id: receipt.id, action: action, request: request)
      })
    else { return false }
    await refreshAll(claimID: claim.id)
    return true
  }

  public func invalidateClaimPreview() {
    claimPreviewGeneration += 1
    claimPreview = nil
    previewedClaimRequest = nil
  }
  public func invalidateReceiptPreview() {
    receiptPreview = nil
    previewedReceiptRequest = nil
    previewedReceiptReplacement = nil
  }
  public func clearPreviews() {
    invalidateClaimPreview()
    invalidateReceiptPreview()
    cancelPreview = nil
  }
  public func clearConflict() { conflictDetected = false }

  @discardableResult private func mutate<T: Sendable>(_ operation: () async throws -> T) async -> T?
  {
    guard !isMutating else { return nil }
    isMutating = true
    message = nil
    conflictDetected = false
    defer { isMutating = false }
    do { return try await operation() } catch {
      apply(error, preserving: true)
      return nil
    }
  }
  private func refreshAll(claimID: UUID) async {
    async let detail = repository.get(id: claimID)
    async let page = repository.list(
      status: statusFilter, includeArchived: includeArchived, cursor: nil, limit: 30)
    async let receipts = repository.receipts(claimID: claimID, cursor: nil, limit: 30)
    async let totals = repository.summary(dateFrom: nil, dateTo: nil)
    async let transactionRefresh: Void = transactions?.load() ?? ()
    async let accountRefresh: Void = accounts?.load() ?? ()
    do {
      let (claim, claimsPage, receiptPage, loadedSummary) = try await (
        detail, page, receipts, totals
      )
      selectedClaim = claim
      claims = claimsPage.items
      nextCursor = claimsPage.nextCursor
      receiptHistory = receiptPage.items
      receiptNextCursor = receiptPage.nextCursor
      summary = loadedSummary
      phase = .loaded
    } catch { refreshMessage = display(error) }
    _ = await (transactionRefresh, accountRefresh)
  }
  private func apply(_ error: Error, preserving: Bool) {
    let text = display(error)
    message = text
    if let api = error as? FiscalAPIError, let code = api.code, Self.isConflictCode(code) {
      conflictDetected = true
    }
    if preserving {
      refreshMessage = text
      phase = claims.isEmpty && selectedClaim == nil ? .failed : .loaded
      return
    }
    guard let api = error as? FiscalAPIError else {
      phase = .failed
      return
    }
    switch api {
    case .unauthorized: phase = .unauthorized
    case .transport: phase = .offline
    default: phase = .failed
    }
  }
  private func display(_ error: Error) -> String {
    (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription
  }
  public nonisolated static func isConflictCode(_ code: String) -> Bool {
    code == "resource_version_conflict" || code == "version_conflict"
      || code == "reimbursement_operation_conflict"
  }
}
