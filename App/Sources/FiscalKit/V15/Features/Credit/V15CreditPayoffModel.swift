import Foundation
import Observation

@MainActor @Observable public final class V15CreditPayoffModel {
    public enum Phase: Equatable { case idle, loading, previewed, submitting, succeeded, unknown, failed(V15Failure) }
    public let accountID: UUID
    public private(set) var phase: Phase = .idle
    public private(set) var preview: V15CreditPayoffPreview?
    public private(set) var receipt: V15CreditPayoffReceipt?
    public private(set) var reversePreview: V15CreditPayoffReversePreview?
    public private(set) var operations: [V15CreditPayoffReceipt] = []
    public private(set) var historyFailure: V15Failure?
    public private(set) var paymentAccounts: [V15AccountResponse] = []
    public private(set) var fieldIssues: [V15FieldIssue] = []
    public var paymentAccountID: UUID? { didSet { inputChanged() } }
    public var occurredAt = Date() { didSet { inputChanged() } }
    public var actualAmountText = "" { didSet { inputChanged() } }
    public var additionalFeeText = "0" { didSet { inputChanged() } }
    public var waivedPrincipalText = "0" { didSet { inputChanged() } }
    public var waivedFeeText = "0" { didSet { inputChanged() } }
    public var bankConfirmedSettled = false { didSet { inputChanged() } }
    public var note = "" { didSet { inputChanged() } }
    public var hasPendingRequest: Bool { pendingID != nil }
    public var canCommit: Bool { phase == .previewed && preview?.executable == true && (preview?.previewExpiresAt ?? .distantPast) > Date() && !hasPendingRequest }
    public var canReverse: Bool { reversePreview?.executable == true && (reversePreview?.previewExpiresAt ?? .distantPast) > Date() && !hasPendingRequest }
    private let services: V15Services
    private var generation: UInt64 = 0
    private var pendingID: UUID?
    private var previewRequest: V15CreditPayoffRequest?
    public init(services: V15Services, accountID: UUID) {
        self.services = services; self.accountID = accountID
        if let item = services.pendingWrites.items.first(where: { $0.resourceID == accountID && ($0.kind == .creditPayoff || $0.kind == .creditPayoffReverse) }) { pendingID = item.id; phase = .unknown }
    }
    public func load() async {
        do { paymentAccounts = try await services.masterData.activeAccounts().filter { $0.kind == .cash || $0.kind == .debit } }
        catch { phase = .failed(failure(error)) }
        await loadHistory()
    }
    public func loadHistory() async {
        do { operations = try await services.payoff.history(accountID: accountID); historyFailure = nil }
        catch { historyFailure = failure(error) }
    }
    public func loadReceipt(operationID: UUID) async {
        generation &+= 1; let current = generation
        do { let value = try await services.payoff.receipt(operationID: operationID); guard current == generation else { return }; receipt = value }
        catch { guard current == generation else { return }; phase = .failed(failure(error)) }
    }
    public func previewPayoff() async {
        guard !hasPendingRequest, phase != .submitting else { return }
        fieldIssues = []
        guard let request = makeRequest() else { return }
        generation &+= 1; let current = generation; phase = .loading; preview = nil
        do {
            let value = try await services.payoff.preview(accountID: accountID, request: request)
            guard current == generation else { return }
            preview = value; previewRequest = request; phase = .previewed
        } catch { guard current == generation else { return }; let value = failure(error); fieldIssues = value.fieldIssues; phase = .failed(value) }
    }
    public func commit() async {
        guard canCommit, let preview, let request = previewRequest else { return }
        let body = V15CreditPayoffCommitRequest(paymentAccountID: request.paymentAccountID, occurredAt: request.occurredAt, actualAmountMinor: request.actualAmountMinor, additionalFeeMinor: request.additionalFeeMinor, waivedPrincipalMinor: request.waivedPrincipalMinor, waivedFeeMinor: request.waivedFeeMinor, bankConfirmedSettled: request.bankConfirmedSettled, note: request.note, previewToken: preview.previewToken)
        do {
            pendingID = try services.pendingWrites.prepare(kind: .creditPayoff, title: "全额结清", request: body, idempotencyKey: UUID(), resourceID: accountID)
            await recoverPending()
        } catch { phase = .failed(failure(error)) }
    }
    public func previewReverse() async {
        guard !hasPendingRequest, let receipt, receipt.status != "reversed" else { return }
        generation &+= 1; let current = generation; phase = .loading; reversePreview = nil
        do { let value = try await services.payoff.reversePreview(operationID: receipt.operationID); guard current == generation else { return }; reversePreview = value; phase = .previewed }
        catch { guard current == generation else { return }; phase = .failed(failure(error)) }
    }
    public func reverse() async {
        guard canReverse, let receipt, let reversePreview else { return }
        do {
            let request = V15JournalPayoffReverse(operationID: receipt.operationID, previewToken: reversePreview.previewToken)
            pendingID = try services.pendingWrites.prepare(kind: .creditPayoffReverse, title: "撤销整组结清", request: request, idempotencyKey: UUID(), resourceID: accountID)
            await recoverPending()
        } catch { phase = .failed(failure(error)) }
    }
    /// Only the durable original payload and key may be replayed after a lost response.
    public func recoverPending() async {
        guard phase != .submitting, let id = pendingID, let item = services.pendingWrites.item(id), let payload = item.payload else { return }
        guard services.offlineSnapshotAt == nil else { phase = .unknown; return }
        phase = .submitting
        do {
            try services.pendingWrites.markInFlight(id)
            let value: V15CreditPayoffReceipt
            if item.kind == .creditPayoff {
                let request = try V15BodyEncoder.decode(V15CreditPayoffCommitRequest.self, from: payload)
                value = try await services.payoff.commit(accountID: accountID, request: request, key: id)
            } else {
                let request = try V15BodyEncoder.decode(V15JournalPayoffReverse.self, from: payload)
                value = try await services.payoff.reverse(operationID: request.operationID, request: .init(previewToken: request.previewToken), key: id)
            }
            receipt = value; preview = nil; reversePreview = nil
            try services.pendingWrites.complete(id); pendingID = nil
            services.notifyConfirmedWrite(); phase = .succeeded; await loadHistory()
        } catch {
            let value = failure(error); fieldIssues = value.fieldIssues
            if value.isDefinitiveRejection {
                do { try services.pendingWrites.complete(id); pendingID = nil } catch { services.pendingWrites.markUnknown(id) }
                preview = nil; reversePreview = nil; phase = .failed(value)
            } else { services.pendingWrites.markUnknown(id); phase = .unknown }
        }
    }
    public func dismiss() { generation &+= 1; preview = nil; reversePreview = nil; previewRequest = nil; if !hasPendingRequest { phase = .idle } }
    private func inputChanged() { generation &+= 1; preview = nil; previewRequest = nil; reversePreview = nil; fieldIssues = []; if !hasPendingRequest { phase = .idle } }
    private func makeRequest() -> V15CreditPayoffRequest? {
        guard let paymentAccountID, paymentAccounts.contains(where: { $0.id == paymentAccountID && $0.id != accountID }) else { fieldIssues = [.init(code: "payment_account_required", message: "请选择实际付款的现金或借记账户。", fieldPath: "payment_account_id")]; return nil }
        let inputs = [(actualAmountText, "actual_amount_minor"), (additionalFeeText, "additional_fee_minor"), (waivedPrincipalText, "waived_principal_minor"), (waivedFeeText, "waived_fee_minor")]
        let amounts = inputs.compactMap { CNYAmountParser.minorUnits($0.0) }
        guard amounts.count == 4, amounts.allSatisfy({ $0 >= 0 }) else { fieldIssues = [.init(code: "amount_invalid", message: "实扣、费用及减免须为非负金额，最多两位小数。", fieldPath: "actual_amount_minor")]; return nil }
        guard bankConfirmedSettled else { fieldIssues = [.init(code: "bank_confirmation_required", message: "请先确认银行已全额结清。", fieldPath: "bank_confirmed_settled")]; return nil }
        if amounts.dropFirst().contains(where: { $0 > 0 }) && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fieldIssues = [.init(code: "difference_note_required", message: "存在费用或减免，请填写银行核对说明。", fieldPath: "note")]; return nil }
        return .init(paymentAccountID: paymentAccountID, occurredAt: occurredAt, actualAmountMinor: amounts[0], additionalFeeMinor: amounts[1], waivedPrincipalMinor: amounts[2], waivedFeeMinor: amounts[3], bankConfirmedSettled: bankConfirmedSettled, note: note.isEmpty ? nil : note)
    }
    private func failure(_ error: Error) -> V15Failure { (error as? V15Failure) ?? .init(kind: .responseUnknown, message: "连接中断，原请求已保留，请恢复原请求。") }
}

struct V15JournalPayoffReverse: Codable, Sendable { let operationID: UUID; let previewToken: UUID }
