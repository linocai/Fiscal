import Foundation

public struct V15CreditPayoffRequest: Codable, Sendable, Equatable {
    public let paymentAccountID: UUID
    public let occurredAt: Date
    public let actualAmountMinor: Int64
    public let additionalFeeMinor: Int64
    public let waivedPrincipalMinor: Int64
    public let waivedFeeMinor: Int64
    public let bankConfirmedSettled: Bool
    public let note: String?
    public init(paymentAccountID: UUID, occurredAt: Date, actualAmountMinor: Int64, additionalFeeMinor: Int64, waivedPrincipalMinor: Int64, waivedFeeMinor: Int64, bankConfirmedSettled: Bool, note: String?) { self.paymentAccountID = paymentAccountID; self.occurredAt = occurredAt; self.actualAmountMinor = actualAmountMinor; self.additionalFeeMinor = additionalFeeMinor; self.waivedPrincipalMinor = waivedPrincipalMinor; self.waivedFeeMinor = waivedFeeMinor; self.bankConfirmedSettled = bankConfirmedSettled; self.note = note }
    enum CodingKeys: String, CodingKey { case paymentAccountID = "payment_account_id", occurredAt = "occurred_at", actualAmountMinor = "actual_amount_minor", additionalFeeMinor = "additional_fee_minor", waivedPrincipalMinor = "waived_principal_minor", waivedFeeMinor = "waived_fee_minor", bankConfirmedSettled = "bank_confirmed_settled", note = "note" }
}

public struct V15CreditPayoffCommitRequest: Codable, Sendable, Equatable {
    public let paymentAccountID: UUID
    public let occurredAt: Date
    public let actualAmountMinor: Int64
    public let additionalFeeMinor: Int64
    public let waivedPrincipalMinor: Int64
    public let waivedFeeMinor: Int64
    public let bankConfirmedSettled: Bool
    public let note: String?
    public let previewToken: UUID
    public init(paymentAccountID: UUID, occurredAt: Date, actualAmountMinor: Int64, additionalFeeMinor: Int64, waivedPrincipalMinor: Int64, waivedFeeMinor: Int64, bankConfirmedSettled: Bool, note: String?, previewToken: UUID) { self.paymentAccountID = paymentAccountID; self.occurredAt = occurredAt; self.actualAmountMinor = actualAmountMinor; self.additionalFeeMinor = additionalFeeMinor; self.waivedPrincipalMinor = waivedPrincipalMinor; self.waivedFeeMinor = waivedFeeMinor; self.bankConfirmedSettled = bankConfirmedSettled; self.note = note; self.previewToken = previewToken }
    enum CodingKeys: String, CodingKey { case paymentAccountID = "payment_account_id", occurredAt = "occurred_at", actualAmountMinor = "actual_amount_minor", additionalFeeMinor = "additional_fee_minor", waivedPrincipalMinor = "waived_principal_minor", waivedFeeMinor = "waived_fee_minor", bankConfirmedSettled = "bank_confirmed_settled", note = "note", previewToken = "preview_token" }
}

public struct V15CreditPayoffAllocation: Codable, Sendable, Equatable {
    public let cycleID: UUID?
    public let remainingMinor: Int64
    public let principalMinor: Int64
    public let feeMinor: Int64
    public let repaidMinor: Int64
    public let waivedPrincipalMinor: Int64
    public let waivedFeeMinor: Int64
    public let installmentPlanIDs: [UUID]
    public init(cycleID: UUID?, remainingMinor: Int64, principalMinor: Int64, feeMinor: Int64, repaidMinor: Int64, waivedPrincipalMinor: Int64, waivedFeeMinor: Int64, installmentPlanIDs: [UUID]) { self.cycleID = cycleID; self.remainingMinor = remainingMinor; self.principalMinor = principalMinor; self.feeMinor = feeMinor; self.repaidMinor = repaidMinor; self.waivedPrincipalMinor = waivedPrincipalMinor; self.waivedFeeMinor = waivedFeeMinor; self.installmentPlanIDs = installmentPlanIDs }
    enum CodingKeys: String, CodingKey { case cycleID = "cycle_id", remainingMinor = "remaining_minor", principalMinor = "principal_minor", feeMinor = "fee_minor", repaidMinor = "repaid_minor", waivedPrincipalMinor = "waived_principal_minor", waivedFeeMinor = "waived_fee_minor", installmentPlanIDs = "installment_plan_ids" }
}

public struct V15CreditPayoffPreview: Codable, Sendable, Equatable {
    public let accountID: UUID
    public let paymentAccountID: UUID
    public let previewToken: UUID
    public let previewExpiresAt: Date
    public let dataRevision: Int64
    public let paymentBalanceBeforeMinor: Int64
    public let paymentBalanceAfterMinor: Int64
    public let debtBeforeMinor: Int64
    public let debtAfterMinor: Int64
    public let actualAmountMinor: Int64
    public let principalMinor: Int64
    public let feeMinor: Int64
    public let additionalFeeMinor: Int64
    public let waivedPrincipalMinor: Int64
    public let waivedFeeMinor: Int64
    public let allocations: [V15CreditPayoffAllocation]
    public let closingInstallmentPlanIDs: [UUID]
    public let warnings: [String]
    public let executable: Bool
    public init(accountID: UUID, paymentAccountID: UUID, previewToken: UUID, previewExpiresAt: Date, dataRevision: Int64, paymentBalanceBeforeMinor: Int64, paymentBalanceAfterMinor: Int64, debtBeforeMinor: Int64, debtAfterMinor: Int64, actualAmountMinor: Int64, principalMinor: Int64, feeMinor: Int64, additionalFeeMinor: Int64, waivedPrincipalMinor: Int64, waivedFeeMinor: Int64, allocations: [V15CreditPayoffAllocation], closingInstallmentPlanIDs: [UUID], warnings: [String], executable: Bool) { self.accountID = accountID; self.paymentAccountID = paymentAccountID; self.previewToken = previewToken; self.previewExpiresAt = previewExpiresAt; self.dataRevision = dataRevision; self.paymentBalanceBeforeMinor = paymentBalanceBeforeMinor; self.paymentBalanceAfterMinor = paymentBalanceAfterMinor; self.debtBeforeMinor = debtBeforeMinor; self.debtAfterMinor = debtAfterMinor; self.actualAmountMinor = actualAmountMinor; self.principalMinor = principalMinor; self.feeMinor = feeMinor; self.additionalFeeMinor = additionalFeeMinor; self.waivedPrincipalMinor = waivedPrincipalMinor; self.waivedFeeMinor = waivedFeeMinor; self.allocations = allocations; self.closingInstallmentPlanIDs = closingInstallmentPlanIDs; self.warnings = warnings; self.executable = executable }
    enum CodingKeys: String, CodingKey { case accountID = "account_id", paymentAccountID = "payment_account_id", previewToken = "preview_token", previewExpiresAt = "preview_expires_at", dataRevision = "data_revision", paymentBalanceBeforeMinor = "payment_balance_before_minor", paymentBalanceAfterMinor = "payment_balance_after_minor", debtBeforeMinor = "debt_before_minor", debtAfterMinor = "debt_after_minor", actualAmountMinor = "actual_amount_minor", principalMinor = "principal_minor", feeMinor = "fee_minor", additionalFeeMinor = "additional_fee_minor", waivedPrincipalMinor = "waived_principal_minor", waivedFeeMinor = "waived_fee_minor", allocations = "allocations", closingInstallmentPlanIDs = "closing_installment_plan_ids", warnings = "warnings", executable = "executable" }
}

public struct V15CreditPayoffReceipt: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let accountID: UUID
    public let paymentAccountID: UUID
    public let occurredAt: Date
    public let status: String
    public let dataRevision: Int64
    public let actualAmountMinor: Int64
    public let debtBeforeMinor: Int64
    public let debtAfterMinor: Int64
    public let transactionIDs: [UUID]
    public let allocations: [V15CreditPayoffAllocation]
    public let reversedAt: Date?
    public init(operationID: UUID, accountID: UUID, paymentAccountID: UUID, occurredAt: Date, status: String, dataRevision: Int64, actualAmountMinor: Int64, debtBeforeMinor: Int64, debtAfterMinor: Int64, transactionIDs: [UUID], allocations: [V15CreditPayoffAllocation], reversedAt: Date?) { self.operationID = operationID; self.accountID = accountID; self.paymentAccountID = paymentAccountID; self.occurredAt = occurredAt; self.status = status; self.dataRevision = dataRevision; self.actualAmountMinor = actualAmountMinor; self.debtBeforeMinor = debtBeforeMinor; self.debtAfterMinor = debtAfterMinor; self.transactionIDs = transactionIDs; self.allocations = allocations; self.reversedAt = reversedAt }
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", accountID = "account_id", paymentAccountID = "payment_account_id", occurredAt = "occurred_at", status = "status", dataRevision = "data_revision", actualAmountMinor = "actual_amount_minor", debtBeforeMinor = "debt_before_minor", debtAfterMinor = "debt_after_minor", transactionIDs = "transaction_ids", allocations = "allocations", reversedAt = "reversed_at" }
}

public struct V15CreditPayoffReversePreview: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let previewToken: UUID
    public let previewExpiresAt: Date
    public let dataRevision: Int64
    public let executable: Bool
    public let warnings: [String]
    public init(operationID: UUID, previewToken: UUID, previewExpiresAt: Date, dataRevision: Int64, executable: Bool, warnings: [String]) { self.operationID = operationID; self.previewToken = previewToken; self.previewExpiresAt = previewExpiresAt; self.dataRevision = dataRevision; self.executable = executable; self.warnings = warnings }
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", previewToken = "preview_token", previewExpiresAt = "preview_expires_at", dataRevision = "data_revision", executable = "executable", warnings = "warnings" }
}

public struct V15CreditPayoffReverseRequest: Codable, Sendable, Equatable {
    public let previewToken: UUID
    public init(previewToken: UUID) { self.previewToken = previewToken }
    enum CodingKeys: String, CodingKey { case previewToken = "preview_token" }
}

public struct V15CreditPayoffService: Sendable {
    private let transport: any V15Transporting
    private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func preview(accountID: UUID, request: V15CreditPayoffRequest) async throws -> V15CreditPayoffPreview { try await writable(); return try await transport.send(.init(path: "credit-accounts/\(accountID)/payoff-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func commit(accountID: UUID, request: V15CreditPayoffCommitRequest, key: UUID) async throws -> V15CreditPayoffReceipt { try await writable(); return try await transport.send(.init(path: "credit-accounts/\(accountID)/payoff", method: "POST", headers: ["Idempotency-Key": key.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func history(accountID: UUID) async throws -> [V15CreditPayoffReceipt] { try await transport.send(.init(path: "credit-accounts/\(accountID)/payoffs", readCachePolicy: .reloadIgnoringCache), body: nil) }
    public func receipt(operationID: UUID) async throws -> V15CreditPayoffReceipt { try await transport.send(.init(path: "credit-payoffs/\(operationID)", readCachePolicy: .reloadIgnoringCache), body: nil) }
    public func reversePreview(operationID: UUID) async throws -> V15CreditPayoffReversePreview { try await writable(); return try await transport.send(.init(path: "credit-payoffs/\(operationID)/reverse-preview", method: "POST"), body: nil) }
    public func reverse(operationID: UUID, request: V15CreditPayoffReverseRequest, key: UUID) async throws -> V15CreditPayoffReceipt { try await writable(); return try await transport.send(.init(path: "credit-payoffs/\(operationID)/reverse", method: "POST", headers: ["Idempotency-Key": key.uuidString]), body: try V15BodyEncoder.encode(request)) }
}
