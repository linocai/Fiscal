import Foundation

public enum V15F3CFixtures {
    public static let claimID = UUID(uuidString: "00000000-0000-0000-0000-00000000C301")!
    public static let partyID = UUID(uuidString: "00000000-0000-0000-0000-00000000C302")!
    public static let allocationID = UUID(uuidString: "00000000-0000-0000-0000-00000000C303")!
    public static let candidateID = UUID(uuidString: "00000000-0000-0000-0000-00000000C304")!
    public static let categoryCandidateID = UUID(uuidString: "00000000-0000-0000-0000-00000000C305")!
    public static let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000C306")!
    public static let receiptID = UUID(uuidString: "00000000-0000-0000-0000-00000000C307")!
    public static let transactionID = UUID(uuidString: "00000000-0000-0000-0000-00000000C308")!
    public static let previewID = UUID(uuidString: "00000000-0000-0000-0000-00000000C309")!
    public static let disabledCandidateID = UUID(uuidString: "00000000-0000-0000-0000-00000000C310")!
    public static let unknownClaimID = UUID(uuidString: "00000000-0000-0000-0000-00000000C313")!

    @MainActor public static func services(route: String = "reimbursements") -> V15Services { .init(transport: F3CTransport(mode: .route(route))) }
    @MainActor static func services(transport: F3CTransport, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil) -> V15Services { .init(transport: transport, offlineSnapshotProvider: offlineSnapshotProvider) }

    static func claim(status: String = "partial_received", version: Int = 3, received: Int64 = 12_000, archived: Bool = false, voided: Bool = false, long: Bool = false, receiptCount explicitReceiptCount: Int? = nil, submitted explicitSubmitted: Bool? = nil) -> String {
        let total: Int64 = 30_000; let outstanding = max(total - received, 0)
        let receiptCount = explicitReceiptCount ?? (received > 0 ? 1 : 0)
        let submitted = explicitSubmitted ?? (status != "draft")
        let title = long ? "一段很长的中文报销单标题，用来验证辅助功能五级字号与窄窗口下每一条禁用原因仍然完整可读" : "八月差旅报销"
        let latest = receiptCount > 0 ? receipt(amount: max(received, 12_000), claimVersion: version, voided: received == 0) : "null"
        return """
        {"id":"\(claimID)","title":"\(title)","note":"仅为离线合成验收数据","status":"\(status)","total_claimed_minor":\(total),"received_minor":\(received),"outstanding_minor":\(outstanding),"expense_count":1,"party_count":1,"receipt_count":\(receiptCount),"parties":[\(party(received: received))],"latest_receipt":\(latest),"version":\(version),"submitted_at":\(submitted ? "\"2026-08-12T01:00:00Z\"" : "null"),"cancelled_at":\(status.contains("cancelled") ? "\"2026-08-15T01:00:00Z\"" : "null"),"voided_at":\(voided ? "\"2026-08-15T03:00:00Z\"" : "null"),"archived_at":\(archived ? "\"2026-08-15T02:00:00Z\"" : "null"),"created_at":"2026-08-10T01:00:00Z","updated_at":"2026-08-15T02:00:00Z"}
        """
    }
    static func party(received: Int64) -> String { let outstanding = max(30_000 - received, 0); return """
    {"id":"\(partyID)","name":"示例公司","expected_date":"2026-08-20","note":null,"claimed_minor":30000,"received_minor":\(received),"outstanding_minor":\(outstanding),"status":"\(outstanding == 0 ? "received" : received > 0 ? "partial_received" : "pending")","position":0,"allocations":[{"id":"\(allocationID)","transaction_id":"\(candidateID)","expense_title":"未分类酒店垫付","expense_amount_minor":30000,"amount_minor":30000,"received_minor":\(received),"outstanding_minor":\(outstanding),"locked":\(received > 0),"position":0}]}
    """ }
    static func transaction(amount: Int64 = 12_000, voided: Bool = false) -> String { """
    {"id":"\(transactionID)","kind":"reimbursement_receipt","amount_minor":\(amount),"occurred_at":"2026-08-15T04:00:00Z","business_date":"2026-08-15","title":"公司回款","note":null,"category_id":null,"account_id":"\(accountID)","destination_account_id":null,"credit_cycle_id":null,"source":"system","postings":[],"version":1,"voided_at":\(voided ? "\"2026-08-15T05:00:00Z\"" : "null"),"created_at":"2026-08-15T04:00:00Z","updated_at":"2026-08-15T04:00:00Z","installment_plan_id":null,"installment_relation":null,"reimbursement_relations":[],"available_actions":[]}
    """ }
    static func receipt(amount: Int64 = 12_000, claimVersion: Int = 3, version: Int = 1, voided: Bool = false) -> String { """
    {"id":"\(receiptID)","claim_id":"\(claimID)","party_id":"\(partyID)","amount_minor":\(amount),"received_at":"2026-08-15T04:00:00Z","destination_account_id":"\(accountID)","title":"公司回款","note":null,"transaction":\(transaction(amount: amount, voided: voided)),"allocations":[{"id":"00000000-0000-0000-0000-00000000C311","allocation_id":"\(allocationID)","amount_minor":\(amount),"position":0}],"version":\(version),"voided_at":\(voided ? "\"2026-08-15T05:00:00Z\"" : "null"),"created_at":"2026-08-15T04:00:00Z","updated_at":"2026-08-15T04:00:00Z"}
    """ }
    static func claims(received: Int64 = 12_000, status: String = "partial_received", voided: Bool = false, long: Bool = false) -> String { let unknown = claim(status: "future_server_state", version: 8, received: 0).replacingOccurrences(of: claimID.uuidString, with: unknownClaimID.uuidString); return "{\"items\":[\(claim(status: status, received: received, voided: voided, long: long)),\(unknown)],\"next_cursor\":null}" }
    static func claims(primary: String) -> String { let unknown = claim(status: "future_server_state", version: 8, received: 0).replacingOccurrences(of: claimID.uuidString, with: unknownClaimID.uuidString); return "{\"items\":[\(primary),\(unknown)],\"next_cursor\":null}" }
    static func receipts(amount: Int64 = 12_000, version: Int = 1, voided: Bool = false, include: Bool = true) -> String { include ? "{\"items\":[\(receipt(amount: amount, version: version, voided: voided))],\"next_cursor\":null}" : "{\"items\":[],\"next_cursor\":null}" }
    static let candidates = """
    {"items":[{"transaction_id":"\(candidateID)","title":"未分类酒店垫付","business_date":"2026-08-10","kind":"expense","account_id":"\(accountID)","category_id":null,"canonical_amount_minor":30000,"allocated_minor":0,"available_minor":30000,"eligibility":{"eligible":true,"transaction_id":"\(candidateID)","canonical_amount_minor":30000,"allocated_minor":0,"available_minor":30000,"reasons":[],"reason_details":[]}},{"transaction_id":"\(disabledCandidateID)","title":"已全部分摊的交通垫付","business_date":"2026-08-09","kind":"expense","account_id":"\(accountID)","category_id":"\(categoryCandidateID)","canonical_amount_minor":8000,"allocated_minor":8000,"available_minor":0,"eligibility":{"eligible":false,"transaction_id":"\(disabledCandidateID)","canonical_amount_minor":8000,"allocated_minor":8000,"available_minor":0,"reasons":["fully_allocated"],"reason_details":[{"code":"fully_allocated","message":"这笔垫付已经没有可报销余额。","field_path":"amount_minor"}]}}],"next_cursor":null}
    """
    static let accounts = "{\"items\":[{\"id\":\"\(accountID)\",\"name\":\"日常借记账户\",\"kind\":\"debit\"}]}"
    static func receiptPreview(claimVersion: Int = 3, receiptVersion: Int? = nil, amount: Int64 = 18_000) -> String { """
    {"preview_token":"\(previewID)","input_digest":"fixture-receipt-input","claim_version":\(claimVersion),"receipt_version":\(receiptVersion.map(String.init) ?? "null"),"claim_before":\(claim(version: claimVersion, received: 12000)),"claim_after":\(claim(status: "received", version: claimVersion, received: 30000)),"party_id":"\(partyID)","amount_minor":\(amount),"party_received_before_minor":12000,"party_received_after_minor":30000,"claim_received_before_minor":12000,"claim_received_after_minor":30000,"persisted_allocations":[{"id":"00000000-0000-0000-0000-00000000C312","allocation_id":"\(allocationID)","amount_minor":\(amount),"position":0}]}
    """ }
    static func cancelPreview() -> String { """
    {"preview_token":"\(previewID)","input_digest":"fixture-cancel-input","claim_version":3,"receipt_version":null,"current":\(claim()),"proposed_status":"partially_received_cancelled","released_minor":18000,"retained_received_minor":12000}
    """ }
    static func claimPreview() -> String { """
    {"preview_token":"\(previewID)","input_digest":"fixture-claim-input","claim_version":3,"receipt_version":null,"current":\(claim()),"proposed":\(claim()),"released_minor":0,"newly_claimed_minor":0,"warnings":["服务端矩阵没有金额变化"]}
    """ }
}

actor F3CTransport: V15Transporting {
    enum Mode: Equatable { case normal, candidateEmpty, candidateErrorThenSuccess, candidateRace, accountEmpty, accountErrorThenSuccess, accountLoading, receiptConflictThenSuccess, receiptRemoteFieldThenSuccess, receiptUnknownThenSuccess, receiptDelayedSuccess, receiptDelayedFailure, receiptReplaceRefresh, receiptDirectRefresh, receiptFactRefreshFailure, claimUnknownThenSuccess, claimDraft, claimPending, claimCancelled, claimVoided, claimReceived, claimArchived, directClaimUnknownConfirmed, directClaimUnknownPrealready, directClaimUnknownNoAdvance, directClaimUnknownMismatch, directClaimReadbackFailure, directReceiptUnknownConfirmed, long, partial
        static func route(_ route: String) -> Mode { switch route { case "reimbursements-candidates-empty": .candidateEmpty; case "reimbursements-candidates-retry": .candidateErrorThenSuccess; case "reimbursements-receipt-empty": .accountEmpty; case "reimbursements-receipt-retry": .accountErrorThenSuccess; case "reimbursements-receipt-loading": .accountLoading; case "reimbursements-conflict": .receiptConflictThenSuccess; case "reimbursements-remote-reasons": .receiptRemoteFieldThenSuccess; case "reimbursements-receipt-unknown": .receiptUnknownThenSuccess; case "reimbursements-receipt-refresh-failure": .receiptFactRefreshFailure; case "reimbursements-claim-unknown": .claimUnknownThenSuccess; case "reimbursements-actions-draft": .claimDraft; case "reimbursements-actions-pending": .claimPending; case "reimbursements-actions-cancelled": .claimCancelled; case "reimbursements-actions-voided": .claimVoided; case "reimbursements-actions-received": .claimReceived; case "reimbursements-actions-archived": .claimArchived; case "reimbursements-direct-readback": .directClaimUnknownConfirmed; case "reimbursements-long": .long; case "reimbursements-partial": .partial; default: .normal } }
    }
    struct Wire: Sendable, Equatable { let method: String; let path: String; let query: String; let key: String?; let body: String; let cache: V15ReadCachePolicy }
    let mode: Mode
    private var wires: [Wire] = []
    private var candidateRequests = 0
    private var accountRequests = 0
    private var receiptPreviews = 0
    private var receiptCommits = 0
    private var claimCreates = 0
    private var directClaimMutationObserved = false
    private var directReceiptMutationObserved = false
    private var currentClaimVersion = 3
    private var currentReceiptVersion = 1
    private var currentReceiptAmount: Int64 = 12_000
    private var currentReceiptVoided = false
    private var factRefreshFailures = 0
    init(mode: Mode) { self.mode = mode }
    func recordedWires() -> [Wire] { wires }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let bodyText = body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? ""
        let queryText = request.query.map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        wires.append(.init(method: request.method, path: request.path, query: queryText, key: request.headers["Idempotency-Key"], body: bodyText, cache: request.readCachePolicy))
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        let received: Int64 = currentReceiptVoided ? 0 : currentReceiptAmount
        switch (request.path, request.method) {
        case ("reimbursement-claims", "GET"):
            if let scenario = actionScenarioClaim() { return try decode(V15F3CFixtures.claims(primary: scenario)) }
            let direct = mode == .directClaimUnknownConfirmed || mode == .directClaimUnknownPrealready || mode == .directClaimUnknownNoAdvance || mode == .directClaimUnknownMismatch || mode == .directClaimReadbackFailure
            return try decode(V15F3CFixtures.claims(received: direct ? 0 : received, status: direct ? "draft" : received == 30_000 ? "received" : received == 0 ? "pending" : "partial_received", voided: mode == .directClaimUnknownPrealready, long: mode == .long))
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)", "GET"):
            if let scenario = actionScenarioClaim() { return try decode(scenario) }
            if mode == .directClaimReadbackFailure, directClaimMutationObserved { throw V15Failure(kind: .transport, code: "readback_failed", message: "fresh GET 失败。") }
            if mode == .directClaimUnknownNoAdvance, directClaimMutationObserved { return try decode(V15F3CFixtures.claim(status: "draft", version: 3, received: 0)) }
            if mode == .directClaimUnknownMismatch, directClaimMutationObserved { return try decode(V15F3CFixtures.claim(status: "draft", version: 4, received: 0, archived: true)) }
            if mode == .receiptFactRefreshFailure, currentClaimVersion > 3, factRefreshFailures == 0 { factRefreshFailures += 1; throw V15Failure(kind: .transport, code: "fact_refresh_failed", message: "最新报销事实读取失败。") }
            let direct = mode == .directClaimUnknownConfirmed || mode == .directClaimUnknownPrealready || mode == .directClaimUnknownNoAdvance || mode == .directClaimUnknownMismatch || mode == .directClaimReadbackFailure
            return try decode(V15F3CFixtures.claim(status: direct ? "draft" : received == 30_000 ? "received" : received == 0 ? "pending" : "partial_received", version: directClaimMutationObserved ? 4 : currentClaimVersion, received: direct ? 0 : received, voided: directClaimMutationObserved || mode == .directClaimUnknownPrealready, long: mode == .long, receiptCount: direct ? 0 : 1))
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)/receipts", "GET"):
            if actionScenarioClaim() != nil { return try decode(V15F3CFixtures.receipts(amount: currentReceiptAmount, version: currentReceiptVersion, voided: currentReceiptVoided, include: actionScenarioHasReceipt)) }
            let direct = mode == .directClaimUnknownConfirmed || mode == .directClaimUnknownPrealready || mode == .directClaimUnknownNoAdvance || mode == .directClaimUnknownMismatch || mode == .directClaimReadbackFailure
            return try decode(V15F3CFixtures.receipts(amount: currentReceiptAmount, version: currentReceiptVersion, voided: currentReceiptVoided, include: !direct))
        case ("reimbursement-claims/\(V15F3CFixtures.unknownClaimID)", "GET"): return try decode(V15F3CFixtures.claim(status: "future_server_state", version: 8, received: 0).replacingOccurrences(of: V15F3CFixtures.claimID.uuidString, with: V15F3CFixtures.unknownClaimID.uuidString))
        case ("reimbursement-claims/\(V15F3CFixtures.unknownClaimID)/receipts", "GET"): return try decode("{\"items\":[],\"next_cursor\":null}")
        case ("reimbursement-receipts/\(V15F3CFixtures.receiptID)", "GET"): return try decode(V15F3CFixtures.receipt(amount: currentReceiptAmount, version: currentReceiptVersion, voided: currentReceiptVoided))
        case ("reimbursement-expense-candidates", "GET"):
            candidateRequests += 1
            let candidateRequest = candidateRequests
            if mode == .candidateRace, candidateRequest == 1 { try await Task.sleep(for: .milliseconds(150)); return try decode("{\"items\":[],\"next_cursor\":null}") }
            if mode == .candidateErrorThenSuccess, candidateRequests == 1 { throw V15Failure(kind: .transport, code: "candidate_load_failed", message: "垫付候选读取失败。") }
            if mode == .candidateEmpty { return try decode("{\"items\":[],\"next_cursor\":null}") }
            return try decode(V15F3CFixtures.candidates)
        case ("reimbursement-receipt-account-options", "GET"):
            accountRequests += 1
            if mode == .accountLoading { try await Task.sleep(for: .seconds(5)) }
            if mode == .accountErrorThenSuccess, accountRequests == 1 { throw V15Failure(kind: .transport, code: "account_load_failed", message: "收款账户读取失败。") }
            if mode == .accountEmpty { return try decode("{\"items\":[]}") }
            return try decode(V15F3CFixtures.accounts)
        case ("reimbursement-claims", "POST"):
            claimCreates += 1
            if mode == .claimUnknownThenSuccess, claimCreates == 1 { throw V15Failure(kind: .responseUnknown, message: "新建结果未知。") }
            return try decode(V15F3CFixtures.claim(status: "draft", version: 1, received: 0))
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)/receipt-preview", "POST"):
            receiptPreviews += 1
            if mode == .receiptConflictThenSuccess, receiptPreviews == 1 { throw V15Failure(kind: .conflict, code: "version_conflict", message: "报销单版本已变化。", conflict: .init(reloadPath: "/api/v1/reimbursement-claims/\(V15F3CFixtures.claimID)", latestRevision: nil, currentVersion: 4, expectedVersion: 3, safeToReload: true, message: "报销单版本已变化。")) }
            if mode == .receiptRemoteFieldThenSuccess, receiptPreviews == 1 { throw V15Failure(kind: .transport, code: "validation_error", message: "请修正到账字段。", fieldIssues: [.init(code: "account_inactive", message: "该收款账户已停用，请重新选择。", fieldPath: "destination_account_id"), .init(code: "title_invalid", message: "到账标题与服务端规则不符。", fieldPath: "title")]) }
            return try decode(V15F3CFixtures.receiptPreview(claimVersion: 3))
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)/receipts", "POST"):
            receiptCommits += 1
            if mode == .receiptDelayedSuccess || mode == .receiptDelayedFailure { try await Task.sleep(for: .milliseconds(120)) }
            if mode == .receiptDelayedFailure { throw V15Failure(kind: .transport, code: "receipt_rejected", message: "到账提交失败。") }
            if mode == .receiptUnknownThenSuccess, receiptCommits == 1 { throw V15Failure(kind: .responseUnknown, message: "到账响应未知。") }
            currentReceiptAmount = 30_000; currentReceiptVersion += 1; currentClaimVersion += 1; currentReceiptVoided = false
            return try decode(V15F3CFixtures.receipt(amount: 18_000, version: currentReceiptVersion))
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)/cancel-preview", "POST"): return try decode(V15F3CFixtures.cancelPreview())
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)/cancel-outstanding", "POST"): return try decode(V15F3CFixtures.claim(status: "partially_received_cancelled", version: 4))
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)/preview", "POST"): return try decode(V15F3CFixtures.claimPreview())
        case ("reimbursement-claims/\(V15F3CFixtures.claimID)", "PUT"): return try decode(V15F3CFixtures.claim(version: 4))
        case ("reimbursement-receipts/\(V15F3CFixtures.receiptID)/preview", "POST"): return try decode(V15F3CFixtures.receiptPreview(receiptVersion: 1))
        case ("reimbursement-receipts/\(V15F3CFixtures.receiptID)", "PUT"):
            let replacement = try V15FixtureCodec.decoder.decode(V15ReimbursementReceiptReplaceCommitRequest.self, from: Data(bodyText.utf8))
            currentReceiptAmount = replacement.amountMinor; currentReceiptVersion += 1; currentClaimVersion += 1; currentReceiptVoided = false
            return try decode(V15F3CFixtures.receipt(amount: currentReceiptAmount, version: currentReceiptVersion))
        case (let path, "POST") where path.hasPrefix("reimbursement-claims/\(V15F3CFixtures.claimID)/"):
            if (mode == .directClaimUnknownConfirmed || mode == .directClaimUnknownPrealready || mode == .directClaimUnknownNoAdvance || mode == .directClaimUnknownMismatch || mode == .directClaimReadbackFailure), path.hasSuffix("/void"), !directClaimMutationObserved { directClaimMutationObserved = true; throw V15Failure(kind: .responseUnknown, message: "直接命令响应未知。") }
            let action = String(path.split(separator: "/").last ?? "")
            let status = action == "submit" ? "pending" : action == "reopen" ? "pending" : action == "retract-submission" ? "draft" : "pending"
            return try decode(V15F3CFixtures.claim(status: status, version: 4))
        case (let path, "POST") where path.hasPrefix("reimbursement-receipts/\(V15F3CFixtures.receiptID)/"):
            if mode == .directReceiptUnknownConfirmed, path.hasSuffix("/void"), !directReceiptMutationObserved {
                directReceiptMutationObserved = true; currentReceiptVoided = true; currentReceiptVersion += 1; currentClaimVersion += 1
                throw V15Failure(kind: .responseUnknown, message: "到账直接命令响应未知。")
            }
            currentReceiptVoided = path.hasSuffix("/void"); currentReceiptVersion += 1; currentClaimVersion += 1
            return try decode(V15F3CFixtures.receipt(amount: currentReceiptAmount, version: currentReceiptVersion, voided: currentReceiptVoided))
        default: throw V15Failure(kind: .transport, code: "fixture_missing", message: "F3-C fixture unsupported: \(request.method) \(request.path)")
        }
    }
    private var actionScenarioHasReceipt: Bool { mode == .claimReceived || mode == .claimArchived }
    private func actionScenarioClaim() -> String? {
        switch mode {
        case .claimDraft: return V15F3CFixtures.claim(status: "draft", received: 0, receiptCount: 0, submitted: false)
        case .claimPending: return V15F3CFixtures.claim(status: "pending", received: 0, receiptCount: 0, submitted: true)
        case .claimCancelled: return V15F3CFixtures.claim(status: "cancelled", received: 0, receiptCount: 0, submitted: true)
        case .claimVoided: return V15F3CFixtures.claim(status: "draft", received: 0, voided: true, receiptCount: 0, submitted: false)
        case .claimReceived: return V15F3CFixtures.claim(status: "received", received: 30_000, receiptCount: 1, submitted: true)
        case .claimArchived: return V15F3CFixtures.claim(status: "received", received: 30_000, archived: true, receiptCount: 1, submitted: true)
        default: return nil
        }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-C 没有文件产物。") }
}
