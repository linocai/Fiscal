import Foundation
import Testing
@testable import FiscalKit

@Suite("F1-C master-data contracts") struct F1CTests {
    @Test("account ordering reads the server revision before writing it") @MainActor func accountOrder() async throws {
        let transport = V15F1CFixtureTransport(); let services = V15Services(transport: transport)
        let state = try await services.masterData.accountOrderState()
        _ = try await services.masterData.reorderAccounts(.init(orderedIDs: state.items.map(\.id), expectedListRevision: state.listRevision))
        let request = try #require(await transport.lastRequest()); #expect(request.path == "accounts/order" && request.method == "PUT")
    }
    @Test("category transform is preview token then idempotent commit") @MainActor func transform() async throws {
        let transport = V15F1CFixtureTransport(); let services = V15Services(transport: transport)
        let preview = try await services.categories.mergePreview(sourceID: V15F1CFixtures.categoryID, request: .init(targetID: V15F1CFixtures.categoryTargetID, sourceExpectedVersion: 2, targetExpectedVersion: 1))
        let receipt = try await services.categories.commitMerge(sourceID: V15F1CFixtures.categoryID, request: .init(previewToken: preview.previewToken), idempotencyKey: UUID())
        #expect(receipt.action == "merge" && receipt.reclassifiedTransactionCount == 4)
        #expect((await transport.lastRequest())?.headers["Idempotency-Key"] != nil)
    }
    @Test("merchant query and mapping carry backend pagination/idempotency/version semantics") @MainActor func merchant() async throws {
        let transport = V15F1CFixtureTransport(); let services = V15Services(transport: transport)
        let page = try await services.merchants.list(query: "咖啡", cursor: "opaque", limit: 30); #expect(page.items.first?.name.contains("咖啡") == true)
        let receipt = try await services.merchants.confirmMapping(transactionID: V15F1CFixtures.transactionID, request: .init(merchantID: V15F1CFixtures.merchantID, expectedMappingVersion: 2), idempotencyKey: UUID())
        #expect(receipt.mapping?.mappingVersion == 2 && receipt.transactionVersion == 3)
    }
    @Test("offline master data rejects mutation") @MainActor func offline() async {
        let model = V15MasterDataModel(services: V15F1CFixtures.services(), offlineSnapshotAt: .now)
        await model.load(); model.accountName = "新账户"; await model.saveAccount()
        #expect(model.receipt?.contains("离线") == true)
    }
    @Test("split uses one preview token and an idempotent commit") @MainActor func split() async throws {
        let transport = V15F1CFixtureTransport(); let services = V15Services(transport: transport)
        let preview = try await services.categories.splitPreview(rootID: V15F1CFixtures.categoryID, request: .init(rootExpectedVersion: 2, children: [.init(name: "子分类一", direction: "expense", parentID: V15F1CFixtures.categoryID, icon: "tag", colorHex: "#008C8A"), .init(name: "子分类二", direction: "expense", parentID: V15F1CFixtures.categoryID, icon: "tag", colorHex: "#008C8A")]))
        let receipt = try await services.categories.commitSplit(rootID: V15F1CFixtures.categoryID, request: .init(previewToken: preview.previewToken, assignments: [.init(transactionID: V15F1CFixtures.transactionID, childName: "子分类一")]), idempotencyKey: UUID())
        #expect(receipt.action == "split")
    }
    @Test("merge and split response-unknown retries keep payload-bound key; input and dismiss invalidate preview") @MainActor func transformRetryLifecycle() async {
        let transport = V15F1CFixtureTransport(unknownTransform: true); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectCategory(model.visibleCategories.first); await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID); await model.commitMerge(); await model.commitMerge()
        let mergeKeys = await transport.idempotencyKeys(path: "categories/\(V15F1CFixtures.categoryID)/merge-commit")
        #expect(mergeKeys.count == 2 && mergeKeys[0] == mergeKeys[1] && model.transformPreview != nil)
        model.invalidatePreview(); #expect(model.transformPreview == nil)
        await model.previewSplit(); await model.commitSplit(); await model.commitSplit()
        let splitKeys = await transport.idempotencyKeys(path: "categories/\(V15F1CFixtures.categoryID)/split-commit")
        #expect(splitKeys.count == 2 && splitKeys[0] == splitKeys[1] && model.splitPreview != nil)
        model.splitChildNames[0] = "已变更"; model.invalidatePreview(); #expect(model.splitPreview == nil)
    }
    @Test("merge preview initializes every child mapping, commits untouched defaults, and blocks empty targets") @MainActor func mergeChildMappingDefaults() async {
        let transport = V15F1CFixtureTransport(mergePreviewData: V15F1CFixtures.multiChildPreview)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectCategory(model.visibleCategories.first)
        await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID)
        #expect(model.childMappings.count == 2)
        #expect(model.childMappings[UUID(uuidString: "00000000-0000-0000-0000-00000000C211")!] == UUID(uuidString: "00000000-0000-0000-0000-00000000C221")!)
        #expect(model.childMappings[UUID(uuidString: "00000000-0000-0000-0000-00000000C212")!] == UUID(uuidString: "00000000-0000-0000-0000-00000000C223")!)
        #expect(await model.commitMerge())
        #expect((await transport.mergeCommitMappings()).count == 2)

        let emptyTransport = V15F1CFixtureTransport(mergePreviewData: V15F1CFixtures.emptyChildTargetPreview)
        let empty = V15MasterDataModel(services: V15Services(transport: emptyTransport))
        await empty.load(); empty.selectCategory(empty.visibleCategories.first); await empty.previewMerge(targetID: V15F1CFixtures.categoryTargetID)
        #expect(empty.childMappings.isEmpty)
        #expect(!(await empty.commitMerge()))
        #expect(empty.transformFieldIssues.contains(where: { $0.code == "child_mapping_required" }))
        #expect((await emptyTransport.paths()).filter { $0.hasSuffix("/merge-commit") }.isEmpty)
    }
    @Test("merge and split preview conflicts reload once, require fresh preview, and do not replay") @MainActor func transformPreviewConflictTakeover() async {
        let transport = F1CConflictTransport(previewConflict: true)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectCategory(model.visibleCategories.first)
        await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID)
        #expect(model.transformPreview == nil && model.transformRequiresRepreview)
        #expect(model.transformMessage?.contains("已重新读取") == true)
        #expect((await transport.mutationPaths()).filter { $0.hasSuffix("/merge-preview") }.count == 1)
        #expect(!(await model.commitMerge()))
        #expect((await transport.mutationPaths()).filter { $0.hasSuffix("/merge-commit") }.isEmpty)
        await model.reloadAfterTransformConflict()
        #expect(await transport.reloadCount() >= 6)
        model.beginTransformFlow(); await model.previewSplit()
        #expect(model.splitPreview == nil && model.transformRequiresRepreview)
        #expect((await transport.mutationPaths()).filter { $0.hasSuffix("/split-preview") }.count == 1)
        #expect(!(await model.commitSplit()))
        #expect((await transport.mutationPaths()).filter { $0.hasSuffix("/split-commit") }.isEmpty)
    }
    @Test("preview transport, offline, and failed conflict reload retain a visible transform failure") @MainActor func transformPreviewFailuresAreExplicit() async {
        let transport = F1CConflictTransport(previewTransportFailure: true)
        let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectCategory(model.visibleCategories.first); await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID)
        #expect(model.transformFailure?.kind == .transport && model.transformMessage?.contains("预览") == true)
        model.beginTransformFlow(); await model.previewSplit()
        #expect(model.transformFailure?.kind == .transport && model.transformMessage?.contains("预览") == true)

        let offline = V15MasterDataModel(services: V15F1CFixtures.services(), offlineSnapshotAt: .now)
        await offline.load(); offline.selectCategory(offline.visibleCategories.first); await offline.previewMerge(targetID: V15F1CFixtures.categoryTargetID)
        #expect(offline.transformFailure?.kind == .offlineReadOnly && offline.transformMessage?.contains("离线") == true)

        let failing = F1CConflictTransport(failReload: true, previewConflict: true)
        let blocked = V15MasterDataModel(services: V15Services(transport: failing))
        await blocked.load(); blocked.selectCategory(blocked.visibleCategories.first); await blocked.previewSplit()
        #expect(blocked.writesRequireExplicitReload && blocked.transformMessage?.contains("重新读取失败") == true)
        await blocked.retryTransformPreview()
        #expect((await failing.mutationPaths()).filter { $0.hasSuffix("/split-preview") }.count == 1)
        #expect(!(await blocked.commitSplit()))
    }
    @Test("reorder conflict reloads authoritative order state") @MainActor func reorderConflictReloads() async {
        let transport = V15F1CFixtureTransport(conflict: true); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); await model.reorderAccounts(moving: V15F1CFixtures.accountID, after: nil)
        #expect((await transport.paths()).filter { $0 == "accounts/order-state" }.count >= 2)
    }
    @Test("mapping unknown reads facts; release retry preserves its idempotency key") @MainActor func mappingUnknownLifecycle() async {
        let transport = V15F1CFixtureTransport(unknownMapping: true); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectMerchant(model.merchants.first); model.mappingTransactionID = V15F1CFixtures.transactionID.uuidString; await model.loadMapping(); await model.confirmMapping()
        #expect(model.receipt?.contains("已确认商户关联保存成功") == true && model.mapping?.mappingVersion == 2)
        await model.releaseMapping(); await model.releaseMapping()
        let keys = await transport.idempotencyKeys(path: "transactions/\(V15F1CFixtures.transactionID)/merchant-mapping")
        #expect(keys.count == 3 && keys[1] == keys[2] && model.receipt?.contains("没有重复操作") == true)
    }
    @Test("merchant next-page failure preserves first page and exposes local retry state") @MainActor func merchantPageFailurePreservesRows() async {
        let model = V15MasterDataModel(services: V15Services(transport: V15F1CFixtureTransport(merchantPageFailure: true)))
        await model.load(); let first = model.merchants.map(\.id); await model.loadNextMerchants()
        #expect(model.merchants.map(\.id) == first && model.merchantPageError != nil && !model.isLoadingMerchants)
    }
    @Test("offline snapshot copy is deterministic Chinese Shanghai time") func offlineSnapshotCopy() {
        #expect(V15OfflineReadOnlyBanner.snapshotLabel(for: Date(timeIntervalSince1970: 1_786_464_000)) == "2026年8月12日 00:00")
    }
    @Test("credit account request only uses backend cycle modes and carries positive-opening dates") func creditAccountWireContract() throws {
        let draft = V15AccountDraft(name: "信用卡", kind: .credit, openingBalanceMinor: 12_000, creditLimitMinor: 50_000, statementDay: 8, dueDay: 25, cycleMode: "statement_day_cutoff", openingBalanceAsOfDate: "2026-08-01", openingDueDate: "2026-08-25")
        let body = try V15BodyEncoder.data(draft)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["cycle_mode"] as? String == "statement_day_cutoff")
        #expect(object?["opening_balance_as_of_date"] as? String == "2026-08-01")
        #expect(object?["opening_due_date"] as? String == "2026-08-25")
    }
    @Test("existing account patch deliberately excludes account kind") func accountPatchDoesNotPretendToChangeKind() throws {
        let body = try V15BodyEncoder.data(V15AccountPatch(expectedVersion: 2, name: "改名", openingBalanceMinor: 100, creditLimitMinor: 10_000, statementDay: 8, dueDay: 25, cycleMode: "previous_calendar_month", openingBalanceAsOfDate: .value("2026-08-01"), openingDueDate: .value("2026-08-25")))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["kind"] == nil)
        #expect(object?["cycle_mode"] as? String == "previous_calendar_month")
    }
    @Test("credit opening dates become explicit JSON null when positive opening is cleared") func creditOpeningDateClearWire() throws {
        let body = try V15BodyEncoder.data(V15AccountPatch(expectedVersion: 2, openingBalanceMinor: 0, openingBalanceAsOfDate: .null, openingDueDate: .null))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(object?["opening_balance_as_of_date"] is NSNull)
        #expect(object?["opening_due_date"] is NSNull)
    }
    @Test("unknown account patch reads the known object and never repeats POST/PATCH") @MainActor func unknownPatchReadback() async {
        let transport = F1CUnknownAccountTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectAccount(model.visibleAccounts.first); model.accountName = "改名"; await model.saveAccount()
        #expect((await transport.patchCount()) == 1)
        #expect((await transport.accountGetCount()) == 1)
        #expect(model.receipt?.contains("没有重复保存") == true)
    }
    @Test("unknown merchant patch is confirmed only by matching GET facts") @MainActor func unknownMerchantPatchApplied() async {
        let transport = F1CUnknownMerchantTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectMerchant(model.merchants.first); await model.saveMerchant()
        #expect(await transport.patchCount() == 1)
        #expect(await transport.getCount() == 1)
        #expect(model.receipt?.contains("已确认商户") == true)
    }
    @Test("unknown category patch with failed readback remains unconfirmed and is not repeated") @MainActor func unknownCategoryReadbackFailed() async {
        let transport = F1CUnknownCategoryTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectCategory(model.visibleCategories.first); model.categoryName = "新版分类"; await model.saveCategory()
        #expect(await transport.patchCount() == 1)
        #expect(await transport.getCount() == 1)
        #expect(model.receipt?.contains("暂时无法确认本次更改") == true)
    }
    @Test("unknown merchant creation refreshes but never guesses an ID or repeats POST") @MainActor func unknownMerchantCreateRefreshesWithoutRetry() async {
        let transport = F1CUnknownMerchantCreateTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectedMerchantID = nil; model.merchantName = "新商户"; await model.saveMerchant()
        #expect(await transport.createCount() == 1)
        #expect(await transport.listCount() >= 2)
        #expect(model.receipt?.contains("新建结果暂时不明") == true)
    }
    @Test("offline guards every owned write entry before transport") @MainActor func offlineGuards() async {
        let transport = F1COfflineTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport), offlineSnapshotAt: .now)
        await model.load(); model.selectAccount(model.visibleAccounts.first); model.selectCategory(model.visibleCategories.first); model.selectMerchant(model.merchants.first); model.mappingTransactionID = V15F1CFixtures.transactionID.uuidString; await transport.resetWrites()
        await model.saveAccount(); await model.archiveOrRestoreAccount(); await model.saveCategory(); await model.archiveOrRestoreCategory(); await model.saveMerchant(); await model.reorderAccounts(moving: V15F1CFixtures.accountID, after: nil); await model.reorderCategories(moving: V15F1CFixtures.categoryID, after: nil); await model.commitMerge(); await model.commitSplit(); await model.confirmMapping(); await model.releaseMapping()
        #expect(await transport.writeCount() == 0)
    }
    @Test("account and category conflicts retain field comparisons until explicit reload and never replay") @MainActor func mutationConflictTakeover() async {
        let transport = F1CConflictTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectAccount(model.visibleAccounts.first); await model.saveAccount()
        #expect(model.writesRequireExplicitReload && model.conflict != nil && !model.conflictChanges.isEmpty)
        await model.archiveOrRestoreAccount()
        #expect((await transport.mutationPaths()).filter { $0.contains("accounts/") }.count == 1)
        await model.resolveConflictByReload()
        #expect(!model.writesRequireExplicitReload && model.conflict == nil)

        model.selectCategory(model.visibleCategories.first); await model.saveCategory()
        #expect(model.writesRequireExplicitReload && model.conflict != nil && !model.conflictChanges.isEmpty)
        await model.resolveConflictByReload()
        #expect(!model.writesRequireExplicitReload && model.conflict == nil)
        #expect(await transport.reloadCount() >= 4)

        let failing = F1CConflictTransport(failReload: true); let blocked = V15MasterDataModel(services: V15Services(transport: failing))
        await blocked.load(); blocked.selectAccount(blocked.visibleAccounts.first); await blocked.saveAccount()
        #expect(blocked.writesRequireExplicitReload && blocked.receipt?.contains("重新读取失败") == true)
        await blocked.saveAccount()
        #expect((await failing.mutationPaths()).count == 1)
    }
    @Test("merge and split conflicts invalidate tokens, reload, and require a fresh preview") @MainActor func transformConflictTakeover() async {
        let transport = F1CConflictTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectCategory(model.visibleCategories.first)
        await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID); await model.commitMerge(); await model.commitMerge()
        #expect(model.transformPreview == nil && model.transformRequiresRepreview)
        #expect((await transport.mutationPaths()).filter { $0.hasSuffix("merge-commit") }.count == 1)
        #expect(model.transformMessage?.contains("重新读取") == true)
        await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID); #expect(model.transformPreview != nil && !model.transformRequiresRepreview)
        model.beginTransformFlow(); await model.previewSplit(); await model.commitSplit(); await model.commitSplit()
        #expect(model.splitPreview == nil && model.transformRequiresRepreview)
        #expect((await transport.mutationPaths()).filter { $0.hasSuffix("split-commit") }.count == 1)
    }
    @Test("transform state never reuses ordinary receipt, conflict, or field issues") @MainActor func transformStateIsIndependent() async {
        let model = V15MasterDataModel(services: V15F1CFixtures.services())
        await model.load(); model.selectMerchant(model.merchants.first); await model.saveMerchant()
        #expect(model.receipt != nil)
        model.selectCategory(model.visibleCategories.first); model.categoryName = ""; await model.saveCategory()
        #expect(!model.fieldIssues.isEmpty)
        await model.previewMerge(targetID: V15F1CFixtures.categoryTargetID)
        #expect(model.transformMessage == nil && model.transformFailure == nil && model.transformFieldIssues.isEmpty)
    }
    @Test("master-data reorder accessibility hints describe the current action and boundary") @MainActor func reorderAccessibilityCopy() {
        #expect(V15MasterDataModel.reorderHint(canMove: true, down: false) == "⌘⌥↑ 上移一位")
        #expect(V15MasterDataModel.reorderHint(canMove: true, down: true) == "⌘⌥↓ 下移一位")
        #expect(V15MasterDataModel.reorderHint(canMove: false, down: false).contains("首位"))
        #expect(V15MasterDataModel.reorderHint(canMove: false, down: true).contains("末位"))
    }
    @Test("unknown account, category, and merchant creates lock the same payload but allow a changed intent") @MainActor func unknownCreateLocksEachEntity() async {
        let accountTransport = F1CUnknownCreateTransport(entity: .account); let account = V15MasterDataModel(services: V15Services(transport: accountTransport))
        await account.load(); account.selectedSection = .accounts; account.accountName = "新账户"; await account.saveAccount(); await account.saveAccount()
        #expect(await accountTransport.createCount() == 1 && account.saveDisabledReason?.code == "create_response_unknown")
        account.accountName = "新账户二"; await account.saveAccount(); #expect(await accountTransport.createCount() == 2)

        let categoryTransport = F1CUnknownCreateTransport(entity: .category); let category = V15MasterDataModel(services: V15Services(transport: categoryTransport))
        await category.load(); category.selectedSection = .categories; category.categoryName = "新分类"; await category.saveCategory(); await category.saveCategory()
        #expect(await categoryTransport.createCount() == 1 && category.saveDisabledReason?.code == "create_response_unknown")
        category.categoryColor = "#113355"; await category.saveCategory(); #expect(await categoryTransport.createCount() == 2)

        let merchantTransport = F1CUnknownCreateTransport(entity: .merchant); let merchant = V15MasterDataModel(services: V15Services(transport: merchantTransport))
        await merchant.load(); merchant.selectedSection = .merchants; merchant.merchantName = "新商户"; merchant.merchantAliases = "甲、乙"; await merchant.saveMerchant(); await merchant.saveMerchant()
        #expect(await merchantTransport.createCount() == 1 && merchant.saveDisabledReason?.code == "create_response_unknown")
        merchant.merchantAliases = "甲、乙、丙"; await merchant.saveMerchant(); #expect(await merchantTransport.createCount() == 2)
    }
    @Test("unknown create only unlocks the same payload after an explicit successful reload") @MainActor func unknownCreateExplicitReload() async {
        let transport = F1CUnknownCreateTransport(entity: .account); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.accountName = "待确认账户"; await model.saveAccount(); await model.saveAccount()
        #expect(await transport.createCount() == 1 && model.unknownCreateReloadReason != nil)
        await model.reloadAfterUnknownCreate()
        #expect(model.saveDisabledReason == nil && model.receipt?.contains("重新读取") == true)
        await model.saveAccount(); #expect(await transport.createCount() == 2)
    }
    @Test("failed unknown-create reload keeps every write locked") @MainActor func unknownCreateReloadFailureLocksWrites() async {
        let transport = F1CUnknownCreateTransport(entity: .category, failReloadAfterCreate: true); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.selectedSection = .categories; model.categoryName = "待确认分类"; await model.saveCategory()
        #expect(model.writeDisabledReason?.code == "reload_required_after_unknown_create")
        model.categoryColor = "#113355"; await model.saveCategory(); await model.reloadAfterUnknownCreate(); await model.saveCategory()
        #expect(await transport.createCount() == 1 && model.writeDisabledReason?.code == "reload_required_after_unknown_create")
    }
    @Test("new account switched from credit to cash or debit omits all hidden credit fields") @MainActor func accountKindSwitchWire() async {
        let transport = F1CAccountCreateBodyTransport(); let model = V15MasterDataModel(services: V15Services(transport: transport))
        await model.load(); model.accountName = "切换账户"; model.accountKind = .credit; model.creditLimit = "1000"; model.statementDay = "5"; model.dueDay = "20"; model.cycleMode = "statement_day_cutoff"; model.openingBalance = "10"; model.openingBalanceAsOfDate = "2026-08-01"; model.openingDueDate = "2026-08-20"
        model.accountKind = .cash; await model.saveAccount()
        model.accountKind = .credit; model.creditLimit = "1000"; model.statementDay = "5"; model.dueDay = "20"; model.cycleMode = "previous_calendar_month"; model.accountKind = .debit; await model.saveAccount()
        let bodies = await transport.createBodies()
        #expect(bodies.count == 2)
        for (index, body) in bodies.enumerated() { guard case .object(let value) = body else { Issue.record("expected account body"); continue }; #expect(value["kind"] == .string(index == 0 ? "cash" : "debit")); #expect(value["credit_limit_minor"] == nil && value["statement_day"] == nil && value["due_day"] == nil && value["cycle_mode"] == nil && value["opening_balance_as_of_date"] == nil && value["opening_due_date"] == nil) }
    }
}

actor F1COfflineTransport: V15Transporting {
    private var writes = 0
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response { if request.method != "GET" { writes += 1; throw V15Failure(kind: .transport, message: "unexpected write") }; let data: Data; switch request.path { case "accounts/order-state": data = V15F1CFixtures.accountState; case "categories": data = V15F1CFixtures.categories; case "merchants": data = V15F1CFixtures.merchantPage; default: data = V15F1CFixtures.mapping }; return try V15FixtureCodec.decoder.decode(Response.self, from: data) }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }; func resetWrites() { writes = 0 }; func writeCount() -> Int { writes }
}

actor F1CUnknownAccountTransport: V15Transporting {
    private var patches = 0; private var gets = 0
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"): data = Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("categories", "GET"): data = V15F1CFixtures.categories
        case ("merchants", "GET"): data = V15F1CFixtures.merchantPage
        case ("accounts/\(V15F1CFixtures.accountID)", "PATCH"): patches += 1; throw V15Failure(kind: .responseUnknown, message: "lost")
        case ("accounts/\(V15F1CFixtures.accountID)", "GET"): gets += 1; data = Data(V15F1CFixtures.account.utf8)
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func patchCount() -> Int { patches }; func accountGetCount() -> Int { gets }
}

actor F1CUnknownMerchantTransport: V15Transporting {
    private var patches = 0; private var gets = 0
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"): data = Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("categories", "GET"): data = V15F1CFixtures.categories
        case ("merchants", "GET"): data = V15F1CFixtures.merchantPage
        case ("merchants/\(V15F1CFixtures.merchantID)", "PATCH"): patches += 1; throw V15Failure(kind: .responseUnknown, message: "lost")
        case ("merchants/\(V15F1CFixtures.merchantID)", "GET"): gets += 1; data = Data(V15F1CFixtures.merchant.utf8)
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func patchCount() -> Int { patches }; func getCount() -> Int { gets }
}

actor F1CUnknownCategoryTransport: V15Transporting {
    private var patches = 0; private var gets = 0
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"): data = Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("categories", "GET"): data = V15F1CFixtures.categories
        case ("merchants", "GET"): data = V15F1CFixtures.merchantPage
        case ("categories/\(V15F1CFixtures.categoryID)", "PATCH"): patches += 1; throw V15Failure(kind: .responseUnknown, message: "lost")
        case ("categories/\(V15F1CFixtures.categoryID)", "GET"): gets += 1; throw V15Failure(kind: .transport, message: "readback unavailable")
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func patchCount() -> Int { patches }; func getCount() -> Int { gets }
}

actor F1CUnknownMerchantCreateTransport: V15Transporting {
    private var creates = 0; private var lists = 0
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"): data = Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("categories", "GET"): data = V15F1CFixtures.categories
        case ("merchants", "GET"): lists += 1; data = V15F1CFixtures.merchantPage
        case ("merchants", "POST"): creates += 1; throw V15Failure(kind: .responseUnknown, message: "lost")
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func createCount() -> Int { creates }; func listCount() -> Int { lists }
}

actor F1CUnknownCreateTransport: V15Transporting {
    enum Entity { case account, category, merchant }
    private let entity: Entity; private let failReloadAfterCreate: Bool
    private var creates = 0; private var created = false
    init(entity: Entity, failReloadAfterCreate: Bool = false) { self.entity = entity; self.failReloadAfterCreate = failReloadAfterCreate }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        if created && failReloadAfterCreate && request.method == "GET" && ["accounts", "categories", "merchants"].contains(request.path) { throw V15Failure(kind: .transport, message: "reload unavailable") }
        if request.method == "POST" && ((entity == .account && request.path == "accounts") || (entity == .category && request.path == "categories") || (entity == .merchant && request.path == "merchants")) { creates += 1; created = true; throw V15Failure(kind: .responseUnknown, message: "lost") }
        let data: Data
        switch request.path {
        case "accounts/order-state": data = V15F1CFixtures.accountState
        case "accounts": data = Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case "categories": data = V15F1CFixtures.categories
        case "merchants": data = V15F1CFixtures.merchantPage
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func createCount() -> Int { creates }
}

actor F1CAccountCreateBodyTransport: V15Transporting {
    private var bodies: [JSONValue] = []
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"): data = Data("[\(V15F1CFixtures.account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("categories", "GET"): data = V15F1CFixtures.categories
        case ("merchants", "GET"): data = V15F1CFixtures.merchantPage
        case ("accounts", "POST"):
            if let body { bodies.append(body) }
            data = Data(V15F1CFixtures.account.utf8)
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func createBodies() -> [JSONValue] { bodies }
}

actor F1CConflictTransport: V15Transporting {
    private let failReload: Bool
    private let previewConflict: Bool
    private let previewTransportFailure: Bool
    private var didMutate = false
    private var accountArchived = false
    private var categoryArchived = false
    private var writes: [String] = []
    private var reloads = 0
    init(failReload: Bool = false, previewConflict: Bool = false, previewTransportFailure: Bool = false) { self.failReload = failReload; self.previewConflict = previewConflict; self.previewTransportFailure = previewTransportFailure }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        if didMutate && failReload && request.method == "GET" && ["accounts", "categories", "merchants"].contains(request.path) {
            throw V15Failure(kind: .transport, message: "reload unavailable")
        }
        let data: Data
        switch (request.path, request.method) {
        case ("accounts/order-state", "GET"): data = V15F1CFixtures.accountState
        case ("accounts", "GET"):
            reloads += 1
            let account = accountArchived ? V15F1CFixtures.archivedAccount : V15F1CFixtures.account
            data = Data("[\(account),\(V15F1CFixtures.accountTwo)]".utf8)
        case ("categories", "GET"):
            reloads += 1
            let category = categoryArchived ? V15F1CFixtures.archivedCategory : V15F1CFixtures.category
            data = Data("[\(category),\(V15F1CFixtures.targetCategory)]".utf8)
        case ("merchants", "GET"): reloads += 1; data = V15F1CFixtures.merchantPage
        case ("accounts/\(V15F1CFixtures.accountID)", "PATCH"), ("accounts/\(V15F1CFixtures.accountID)/archive", "POST"), ("accounts/\(V15F1CFixtures.accountID)/restore", "POST"):
            writes.append(request.path); didMutate = true
            if request.path.hasSuffix("/archive") { accountArchived = true }
            if request.path.hasSuffix("/restore") { accountArchived = false }
            throw conflict
        case ("categories/\(V15F1CFixtures.categoryID)", "PATCH"), ("categories/\(V15F1CFixtures.categoryID)/archive", "POST"), ("categories/\(V15F1CFixtures.categoryID)/restore", "POST"):
            writes.append(request.path); didMutate = true
            if request.path.hasSuffix("/archive") { categoryArchived = true }
            if request.path.hasSuffix("/restore") { categoryArchived = false }
            throw conflict
        case ("categories/\(V15F1CFixtures.categoryID)/merge-preview", "POST"):
            writes.append(request.path)
            if previewConflict { didMutate = true; throw conflict }
            if previewTransportFailure { throw V15Failure(kind: .transport, message: "合并预览网络失败") }
            data = V15F1CFixtures.preview
        case ("categories/\(V15F1CFixtures.categoryID)/split-preview", "POST"):
            writes.append(request.path)
            if previewConflict { didMutate = true; throw conflict }
            if previewTransportFailure { throw V15Failure(kind: .transport, message: "拆分预览网络失败") }
            data = V15F1CFixtures.splitPreview
        case ("categories/\(V15F1CFixtures.categoryID)/merge-commit", "POST"), ("categories/\(V15F1CFixtures.categoryID)/split-commit", "POST"):
            writes.append(request.path); didMutate = true; throw conflict
        default: throw V15Failure(kind: .transport, code: "unexpected", message: request.path)
        }
        return try V15FixtureCodec.decoder.decode(Response.self, from: data)
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { Data() }
    func mutationPaths() -> [String] { writes }
    func reloadCount() -> Int { reloads }
    private var conflict: V15Failure { .init(kind: .conflict, code: "version_conflict", message: "版本已变化", conflict: .init(reloadPath: "/api/v1/accounts", latestRevision: 3, message: "版本已变化")) }
}
