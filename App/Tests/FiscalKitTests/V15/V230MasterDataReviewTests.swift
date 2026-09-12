import Foundation
import Testing
@testable import FiscalKit

@Suite("2.3.0 master data review regressions")
struct V230MasterDataReviewTests {
    @Test(arguments: ["accounts", "categories", "merchants"], ["success", "failure", "conflict", "unknown", "unknownCommitted"])
    @MainActor func lateResponsePreservesSelectionAndNextWriteTarget(kind: String, outcome: String) async throws {
        let transport = MasterReviewTransport(outcome: outcome, delayed: true)
        let services = V15Services(transport: transport)
        let model = V15MasterDataModel(services: services)
        #expect(await model.load())
        select(model, kind: kind, index: 0); setName(model, kind: kind, name: "A submitted")
        let saving = Task { await save(model, kind: kind) }
        await transport.waitUntilStarted()
        select(model, kind: kind, index: 1); setName(model, kind: kind, name: "B draft")
        let target = selectedID(model, kind: kind)
        await transport.release(); await saving.value
        #expect(selectedID(model, kind: kind) == target)
        #expect(name(model, kind: kind) == "B draft")
        #expect(model.receipt == nil && model.fieldIssues.isEmpty && model.conflict == nil)
        #expect(!model.writesRequireExplicitReload)
        if outcome == "success" || outcome == "unknownCommitted" { #expect(services.confirmedWriteRevision > 0) }
        await save(model, kind: kind)
        let paths = await transport.writePaths
        #expect(paths.count == 2)
        let targetID = try #require(target)
        #expect(paths.last?.lowercased() == "\(kind)/\(targetID.uuidString.lowercased())")
    }

    @Test(arguments: ["accounts", "categories", "merchants"])
    @MainActor func editingInFlightCreateBindsIdentityAndNextSavePatches(kind: String) async throws {
        let transport = MasterReviewTransport(delayed: true)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        #expect(await model.load()); select(model, kind: kind, index: 0); model.beginNewDraft()
        setName(model, kind: kind, name: "submitted creation")
        if kind == "accounts" { model.openingBalance = "10" }
        let saving = Task { await save(model, kind: kind) }
        await transport.waitUntilStarted()
        setName(model, kind: kind, name: "newer input")
        if kind == "accounts" { model.openingBalance = "25" }
        await transport.release(); await saving.value
        let createdID = try #require(selectedID(model, kind: kind))
        #expect(name(model, kind: kind) == "newer input")
        #expect(model.receiptStatus != .success && model.receipt == nil)
        if kind == "accounts" {
            #expect(model.openingBalance == "25")
            #expect(model.selectedAccount?.openingBalanceMinor == 1000)
        }
        await save(model, kind: kind)
        #expect(await transport.writeMethods == ["POST", "PATCH"])
        #expect(await transport.writePaths == [kind, "\(kind)/\(createdID.uuidString)"])
        #expect(selectedID(model, kind: kind) == createdID)
        #expect(model.receiptStatus == .success)
        if kind == "accounts" { #expect(model.selectedAccount?.openingBalanceMinor == 2500) }
    }

    @Test(arguments: ["accounts", "categories", "merchants"], [false, true])
    @MainActor func lateCreateOrUpdateCannotSelectOverNewDraft(kind: String, creating: Bool) async {
        let transport = MasterReviewTransport(delayed: true)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        #expect(await model.load()); select(model, kind: kind, index: 0)
        if creating { model.beginNewDraft() }
        setName(model, kind: kind, name: "submitted")
        let saving = Task { await save(model, kind: kind) }
        await transport.waitUntilStarted()
        model.beginNewDraft(); setName(model, kind: kind, name: "new unsaved draft")
        await transport.release(); await saving.value
        #expect(selectedID(model, kind: kind) == nil)
        #expect(name(model, kind: kind) == "new unsaved draft" && model.receipt == nil)
        await save(model, kind: kind)
        #expect(await transport.writePaths.last == kind)
    }

    @Test(arguments: ["accounts", "categories", "merchants"])
    @MainActor func unknownCreateKeepsDuplicateProtectionAfterSwitch(kind: String) async {
        let transport = MasterReviewTransport(outcome: "unknown", delayed: true)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        #expect(await model.load()); select(model, kind: kind, index: 0); model.beginNewDraft()
        setName(model, kind: kind, name: "submitted")
        let saving = Task { await save(model, kind: kind) }
        await transport.waitUntilStarted()
        model.beginNewDraft(); setName(model, kind: kind, name: "different draft")
        await transport.release(); await saving.value
        #expect(model.receipt == nil && selectedID(model, kind: kind) == nil)
        #expect(model.saveDisabledReason?.code == "create_response_unknown")
        await save(model, kind: kind)
        #expect(await transport.writePaths.count == 1)
    }

    @Test(arguments: ["credit_limit_minor", "statement_day", "due_day", "opening_balance_as_of_date", "opening_due_date"], ["committed", "omitted", "staleVersion", "readFailed"])
    @MainActor func unknownAccountReadbackRequiresEverySubmittedFieldAndNewVersion(field: String, scenario: String) async throws {
        let transport = MasterReviewTransport(outcome: "unknownCommitted", ignoredField: scenario == "omitted" ? field : nil, staleVersion: scenario == "staleVersion", readFailed: scenario == "readFailed")
        let services = V15Services(transport: transport)
        let model = V15MasterDataModel(services: services)
        #expect(await model.load())
        model.selectAccount(try #require(model.accounts.first { $0.kind == .credit }))
        switch field {
        case "credit_limit_minor": model.creditLimit = "2000"
        case "statement_day": model.statementDay = "12"
        case "due_day": model.dueDay = "22"
        case "opening_balance_as_of_date": model.openingBalanceAsOfDate = "2026-08-02"
        default: model.openingDueDate = "2026-09-22"
        }
        await model.saveAccount()
        #expect(model.receiptStatus == (scenario == "committed" ? .success : .unknown))
        #expect(services.confirmedWriteRevision == (scenario == "committed" ? 1 : 0))
        #expect(await transport.writePaths.count == 1)
        switch field {
        case "credit_limit_minor": #expect(model.creditLimit == "2000")
        case "statement_day": #expect(model.statementDay == "12")
        case "due_day": #expect(model.dueDay == "22")
        case "opening_balance_as_of_date": #expect(model.openingBalanceAsOfDate == "2026-08-02")
        default: #expect(model.openingDueDate == "2026-09-22")
        }
    }

    @Test(arguments: ["credit_limit_minor", "statement_day", "due_day", "opening_due_date"], [false, true])
    @MainActor func unknownModeChangeMustConfirmExplicitNulls(field: String, committed: Bool) async throws {
        let transport = MasterReviewTransport(outcome: "unknownCommitted", ignoredField: committed ? nil : field)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        #expect(await model.load())
        model.selectAccount(try #require(model.accounts.first { $0.kind == .credit }))
        model.cycleMode = "on_demand"
        await model.saveAccount()
        #expect(model.receiptStatus == (committed ? .success : .unknown))
        #expect(model.cycleMode == "on_demand" && model.openingDueDate.isEmpty)
        #expect(await transport.writePaths.count == 1)
    }

    @Test(arguments: ["accounts", "categories"], [false, true])
    @MainActor func archiveAndRestoreResponsesCannotStealSelection(kind: String, restoring: Bool) async {
        let transport = MasterReviewTransport(delayed: true, archived: restoring)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        #expect(await model.load()); select(model, kind: kind, index: 0)
        let saving = Task {
            if kind == "accounts" { await model.archiveOrRestoreAccount() }
            else { await model.archiveOrRestoreCategory() }
        }
        await transport.waitUntilStarted()
        #expect(model.isSaving)
        select(model, kind: kind, index: 1); setName(model, kind: kind, name: "B draft")
        let target = selectedID(model, kind: kind)
        await transport.release(); await saving.value
        #expect(selectedID(model, kind: kind) == target && name(model, kind: kind) == "B draft")
        #expect(model.receipt == nil && !model.isSaving)
    }

    @MainActor private func select(_ model: V15MasterDataModel, kind: String, index: Int) {
        switch kind {
        case "accounts": model.selectedSection = .accounts; model.selectAccount(model.accounts[index])
        case "categories": model.selectedSection = .categories; model.selectCategory(model.categories[index])
        default: model.selectedSection = .merchants; model.selectMerchant(model.merchants[index])
        }
    }
    @MainActor private func setName(_ model: V15MasterDataModel, kind: String, name: String) {
        switch kind { case "accounts": model.accountName = name; case "categories": model.categoryName = name; default: model.merchantName = name }
    }
    @MainActor private func name(_ model: V15MasterDataModel, kind: String) -> String {
        switch kind { case "accounts": model.accountName; case "categories": model.categoryName; default: model.merchantName }
    }
    @MainActor private func selectedID(_ model: V15MasterDataModel, kind: String) -> UUID? {
        switch kind { case "accounts": model.selectedAccountID; case "categories": model.selectedCategoryID; default: model.selectedMerchantID }
    }
    @MainActor private func save(_ model: V15MasterDataModel, kind: String) async {
        switch kind { case "accounts": await model.saveAccount(); case "categories": await model.saveCategory(); default: await model.saveMerchant() }
    }
}

private actor MasterReviewTransport: V15Transporting {
    private var records: [String: [[String: Any]]]
    private let outcome: String
    private let delayed: Bool
    private let ignoredField: String?
    private let staleVersion: Bool
    private let readFailed: Bool
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var started = false
    private(set) var writePaths: [String] = []
    private(set) var writeMethods: [String] = []

    init(outcome: String = "success", delayed: Bool = false, ignoredField: String? = nil, staleVersion: Bool = false, readFailed: Bool = false, archived: Bool = false) {
        self.outcome = outcome; self.delayed = delayed; self.ignoredField = ignoredField
        self.staleVersion = staleVersion; self.readFailed = readFailed
        var accounts = try! JSONSerialization.jsonObject(with: V15F1AFixtures.accounts) as! [[String: Any]]
        for i in accounts.indices where accounts[i]["kind"] as? String == "credit" {
            accounts[i]["opening_balance_minor"] = 10000
            accounts[i]["credit_limit_minor"] = 100000
            accounts[i]["statement_day"] = 10; accounts[i]["due_day"] = 20
            accounts[i]["cycle_mode"] = "statement_day_cutoff"
            accounts[i]["opening_balance_as_of_date"] = "2026-08-01"
            accounts[i]["opening_due_date"] = "2026-09-20"
        }
        let timestamp = "2026-09-01T00:00:00Z"
        var categories: [[String: Any]] = []
        var merchants: [[String: Any]] = []
        for i in 0..<2 {
            let common: [String: Any] = ["id": UUID().uuidString, "name": "Record \(i)", "version": 1, "created_at": timestamp, "updated_at": timestamp, "aliases": []]
            var category = common
            category.merge(["direction": "expense", "icon": "tag", "color_hex": "#008C8A", "examples": [], "is_balance_adjustment": false, "sort_order": i, "usage_count": 0, "children": []]) { _, new in new }
            categories.append(category); merchants.append(common)
        }
        if archived { accounts[0]["archived_at"] = timestamp; categories[0]["archived_at"] = timestamp }
        records = ["accounts": accounts, "categories": categories, "merchants": merchants]
    }
    func waitUntilStarted() async { if started { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { pending?.resume(); pending = nil }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let parts = request.path.split(separator: "/").map(String.init)
        let kind = parts[0]
        var rows = records[kind] ?? []
        let response: Any
        if request.method != "GET" {
            writePaths.append(request.path)
            writeMethods.append(request.method)
            let first = writePaths.count == 1
            if first && delayed {
                started = true
                await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
            }
            if first && outcome == "failure" { throw V15Failure(kind: .transport, code: "validation_error", message: "Rejected", fieldIssues: [.init(code: "invalid", message: "Rejected", fieldPath: "name")]) }
            if first && outcome == "conflict" { throw V15Failure(kind: .conflict, message: "Conflict") }
            if first && outcome == "unknown" { throw V15Failure(kind: .responseUnknown, message: "Unknown") }
            let fields = try body.map { try JSONSerialization.jsonObject(with: V15BodyEncoder.data($0)) as! [String: Any] } ?? [:]
            let creating = parts.count == 1
            let index: Int
            if creating { var row = rows[0]; row["id"] = UUID().uuidString; rows.append(row); index = rows.count - 1 }
            else { index = rows.firstIndex { ($0["id"] as! String).lowercased() == parts[1].lowercased() }! }
            for (key, value) in fields where key != "expected_version" && key != ignoredField { rows[index][key] = value }
            if parts.last == "archive" { rows[index]["archived_at"] = "2026-09-12T00:00:00Z" }
            if parts.last == "restore" { rows[index]["archived_at"] = NSNull() }
            if !staleVersion { rows[index]["version"] = (rows[index]["version"] as! Int) + 1 }
            records[kind] = rows; response = rows[index]
            if first && outcome == "unknownCommitted" { throw V15Failure(kind: .responseUnknown, message: "Lost reply") }
        } else if request.path == "accounts/order-state" {
            response = ["items": rows, "list_revision": "review"] as [String: Any]
        } else if parts.count > 1 {
            if readFailed && !writePaths.isEmpty { throw V15Failure(kind: .transport, message: "Read failed") }
            response = rows.first { ($0["id"] as! String).lowercased() == parts[1].lowercased() }!
        } else if kind == "merchants" { response = ["items": rows, "next_cursor": NSNull()] as [String: Any] }
        else if kind == "categories" { response = request.query.contains { $0.name == "direction" && $0.value == "income" } ? [] : rows }
        else { response = rows }
        return try V15FixtureCodec.decoder.decode(Response.self, from: JSONSerialization.data(withJSONObject: response))
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw CocoaError(.fileReadUnsupportedScheme) }
}
