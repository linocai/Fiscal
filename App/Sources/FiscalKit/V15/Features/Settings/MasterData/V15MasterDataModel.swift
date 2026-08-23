import Foundation

@MainActor @Observable public final class V15MasterDataModel {
    public enum Section: String, CaseIterable, Identifiable, Equatable { case accounts = "账户", categories = "分类", merchants = "商户"; public var id: String { rawValue } }
    public enum Phase { case idle, loading, loaded, failed(V15Failure) }
    public private(set) var phase: Phase = .idle
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var categories: [V15CategoryResponse] = []
    public private(set) var merchants: [V15Merchant] = []
    public private(set) var accountRevision: String?
    public private(set) var categoryRevisions: [String: String] = [:]
    public private(set) var merchantCursor: String?
    public private(set) var merchantPageError: V15Failure?
    public private(set) var isLoadingMerchants = false
    public private(set) var receipt: String?
    public private(set) var conflict: V15Conflict?
    public private(set) var conflictChanges: [V15ConflictChange] = []
    public private(set) var writesRequireExplicitReload = false
    public private(set) var offlineSnapshotAt: Date?
    public var selectedSection: Section = .accounts
    public var selectedAccountID: UUID?
    public var selectedCategoryID: UUID?
    public var selectedMerchantID: UUID?
    public var accountName = ""; public var accountKind: V15AccountKind = .cash; public var openingBalance = "0"; public var creditLimit = ""; public var statementDay = ""; public var dueDay = ""; public var cycleMode = "statement_day_cutoff"; public var openingBalanceAsOfDate = ""; public var openingDueDate = ""
    public var categoryName = ""; public var categoryDirection: V15CategoryDirection = .expense; public var categoryIcon = "tag"; public var categoryColor = "#008C8A"
    public var merchantName = ""; public var merchantAliases = ""; public var merchantSearch = ""; public private(set) var committedMerchantSearch = ""
    public var mappingTransactionID = ""; public private(set) var mapping: V15MerchantMapping?
    public var fieldIssues: [V15FieldIssue] = []
    public var transformPreview: V15CategoryMergePreview?
    public var transformReceipt: V15CategoryTransformReceipt?
    public private(set) var transformMessage: String?
    public private(set) var transformFailure: V15Failure?
    public private(set) var transformFieldIssues: [V15FieldIssue] = []
    public private(set) var transformRequiresRepreview = false
    public var childMappings: [UUID: UUID] = [:]
    public var splitPreview: V15CategorySplitPreview?
    public var splitChildNames: [String] = ["子分类一", "子分类二"]
    public var splitAssignments: [UUID: String] = [:]
    private let services: V15Services
    private var generation: UInt64 = 0
    private var merchantPageGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private enum TransformPreviewIntent { case merge(UUID), split }
    private struct UnknownCreateLock { let section: Section; let payloadIdentity: String; var explicitlyReloaded = false }
    private var pendingTransformPreview: TransformPreviewIntent?
    private var unknownCreateLock: UnknownCreateLock?
    private let idempotency = V15IdempotencyOwner()

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) { self.services = services; self.offlineSnapshotAt = offlineSnapshotAt }
    public var isOffline: Bool { offlineSnapshotAt != nil }
    public var writeDisabledReason: V15DisabledReason? {
        if isOffline { return .init(code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。", fieldPath: nil) }
        if writesRequireExplicitReload { return unknownCreateLock == nil ? .init(code: "reload_required_after_conflict", message: "上次冲突后的重新读取未完成；请先显式重新读取后再决定。", fieldPath: nil) : .init(code: "reload_required_after_unknown_create", message: "新建结果未确认且重新读取失败；所有写入已停止，请先显式重新读取。", fieldPath: nil) }
        return nil
    }
    public var saveDisabledReason: V15DisabledReason? {
        if let reason = writeDisabledReason { return reason }
        guard let lock = unknownCreateLock, lock.section == selectedSection, !lock.explicitlyReloaded,
              currentCreatePayloadIdentity == lock.payloadIdentity else { return nil }
        return .init(code: "create_response_unknown", message: "上次新建结果未确认；相同草稿不会再次提交。请先显式重新读取后再确认，或修改草稿形成新的提交意图。", fieldPath: nil)
    }
    public var unknownCreateReloadReason: V15DisabledReason? {
        guard let lock = unknownCreateLock, !lock.explicitlyReloaded else { return nil }
        let sameDraft = lock.section == selectedSection && currentCreatePayloadIdentity == lock.payloadIdentity
        return .init(code: "create_response_unknown", message: sameDraft ? "上次新建结果未确认；可重新读取服务器事实，但不会据此猜测已创建。" : "仍有一项新建结果未确认；请重新读取服务器事实后再继续写入。", fieldPath: nil)
    }
    public var selectedAccount: V15AccountResponse? { accounts.first { $0.id == selectedAccountID } }
    public var selectedCategory: V15CategoryResponse? { flatten(categories).first { $0.id == selectedCategoryID } }
    public var selectedMerchant: V15Merchant? { merchants.first { $0.id == selectedMerchantID } }
    public var visibleAccounts: [V15AccountResponse] { accounts.sorted { $0.sortOrder < $1.sortOrder } }
    public var visibleCategories: [V15CategoryResponse] { flatten(categories).sorted { $0.sortOrder < $1.sortOrder } }
    public func accountLabel(_ account: V15AccountResponse) -> String {
        let count = accounts.filter { $0.name.caseInsensitiveCompare(account.name) == .orderedSame }.count
        return count > 1 && account.lastFour != nil ? "\(account.name) · 尾号 \(account.lastFour!)" : account.name
    }
    @discardableResult public func load(preservingConflict: Bool = false) async -> Bool {
        generation &+= 1; merchantPageGeneration &+= 1; isLoadingMerchants = false; merchantPageError = nil; let current = generation; phase = .loading
        do {
            async let accountState = services.masterData.accountOrderState()
            async let allAccounts = services.masterData.accounts(includeArchived: true)
            async let expenses = services.masterData.categories(direction: .expense, includeArchived: true)
            async let incomes = services.masterData.categories(direction: .income, includeArchived: true)
            async let merchantPage = services.merchants.list(query: committedMerchantSearch, limit: 50)
            let state = try await accountState; let accountResult = try await allAccounts; let categoryResult = try await (expenses + incomes); let page = try await merchantPage
            guard current == generation else { return false }
            accounts = accountResult; accountRevision = state.listRevision; categories = categoryResult; merchants = page.items; merchantCursor = page.nextCursor; merchantPageError = nil; isLoadingMerchants = false
            phase = .loaded
            if !preservingConflict { conflict = nil; conflictChanges = []; writesRequireExplicitReload = false }
            return true
        } catch is CancellationError { guard current == generation else { return false }; phase = .idle; return false
        } catch let failure as V15Failure { guard current == generation else { return false }; phase = .failed(failure); return false
        } catch { guard current == generation else { return false }; phase = .failed(.init(kind: .transport, message: "主数据读取失败。")); return false }
    }
    public func selectAccount(_ value: V15AccountResponse?) { selectedAccountID = value?.id; if let value { accountName = value.name; accountKind = value.kind; openingBalance = String(format: "%.2f", Double(value.openingBalanceMinor) / 100); creditLimit = value.creditLimitMinor.map { String(format: "%.2f", Double($0) / 100) } ?? ""; statementDay = value.statementDay.map(String.init) ?? ""; dueDay = value.dueDay.map(String.init) ?? ""; cycleMode = value.cycleMode ?? "statement_day_cutoff"; openingBalanceAsOfDate = value.openingBalanceAsOfDate ?? ""; openingDueDate = value.openingDueDate ?? "" } }
    public func selectCategory(_ value: V15CategoryResponse?) { selectedCategoryID = value?.id; if let value { categoryName = value.name; categoryDirection = V15CategoryDirection(rawValue: value.direction) ?? .unknown; categoryIcon = value.icon; categoryColor = value.colorHex } }
    public func selectMerchant(_ value: V15Merchant?) { selectedMerchantID = value?.id; if let value { merchantName = value.name; merchantAliases = value.aliases.joined(separator: "、") } }
    public func saveAccount() async { guard canWrite("无法保存") else { return }; guard selectedAccount?.archivedAt == nil else { receipt = "归档账户只能恢复，不能编辑。"; return }; guard let minor = CNYAmountParser.minorUnits(openingBalance), !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fieldIssues = [.init(code: "account_required", message: "请填写账户昵称和有效的期初余额。", fieldPath: "account")]; return }; let kind = accountKind; let isCredit = kind == .credit; let credit = isCredit && !creditLimit.isEmpty ? CNYAmountParser.minorUnits(creditLimit) : nil; let statement = isCredit ? Int(statementDay) : nil; let due = isCredit ? Int(dueDay) : nil; let mode = isCredit ? cycleMode : nil; let name = accountName; let allowedModes = ["statement_day_cutoff", "previous_calendar_month"]; let datesValid = openingBalanceAsOfDate.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil && openingDueDate.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil; if isCredit && (credit == nil || statement == nil || due == nil || mode.map(allowedModes.contains) != true || (minor > 0 && !datesValid)) { fieldIssues = [.init(code: "credit_required", message: "信用账户需填写额度、账单日、还款日；正期初还需填写两项上海业务日期。", fieldPath: "credit")]; return }; let asOf = isCredit && minor > 0 ? openingBalanceAsOfDate : nil; let dueDate = isCredit && minor > 0 ? openingDueDate : nil; let account = selectedAccount; let createIdentity = account == nil ? accountCreateIdentity(name: name, kind: kind, opening: minor, credit: credit, statement: statement, due: due, mode: mode, asOf: asOf, dueDate: dueDate) : nil; guard canSubmitCreate(section: .accounts, identity: createIdentity) else { return }; let clearOpeningDates = account?.openingBalanceMinor ?? 0 > 0 && minor == 0; await mutate(id: account?.id, unknownCreateIdentity: createIdentity, confirmed: { $0.name == name && $0.kind == kind && $0.openingBalanceMinor == minor && $0.creditLimitMinor == credit && $0.statementDay == statement && $0.dueDay == due && $0.cycleMode == mode && $0.openingBalanceAsOfDate == asOf && $0.openingDueDate == dueDate }) { [self] in if let account { return try await services.masterData.patchAccount(id: account.id, patch: .init(expectedVersion: account.version, name: name, openingBalanceMinor: minor, creditLimitMinor: credit, statementDay: statement, dueDay: due, cycleMode: mode, openingBalanceAsOfDate: clearOpeningDates ? .null : (asOf.map(V15NullablePatchValue.value) ?? .omitted), openingDueDate: clearOpeningDates ? .null : (dueDate.map(V15NullablePatchValue.value) ?? .omitted))) } else { return try await services.masterData.createAccount(.init(name: name, kind: kind, openingBalanceMinor: minor, creditLimitMinor: credit, statementDay: statement, dueDay: due, cycleMode: mode, openingBalanceAsOfDate: asOf, openingDueDate: dueDate)) } } }
    public func archiveOrRestoreAccount() async { guard canWrite("无法更改") else { return }; guard let account = selectedAccount else { return }; let archiving = account.archivedAt == nil; await mutate(id: account.id, confirmed: { archiving ? $0.archivedAt != nil : $0.archivedAt == nil }) { [self] in archiving ? try await services.masterData.archiveAccount(id: account.id, expectedVersion: account.version) : try await services.masterData.restoreAccount(id: account.id, expectedVersion: account.version) } }
    public func saveCategory() async { guard canWrite("无法保存") else { return }; guard selectedCategory?.archivedAt == nil else { receipt = "归档分类只能恢复，不能编辑。"; return }; guard !categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, categoryColor.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { fieldIssues = [.init(code: "category_required", message: "请填写分类名称和六位颜色值。", fieldPath: "category")]; return }; let category = selectedCategory; let name = categoryName; let direction = categoryDirection.rawValue; let icon = categoryIcon; let color = categoryColor; let createIdentity = category == nil ? identity(["category", name, direction, icon, color]) : nil; guard canSubmitCreate(section: .categories, identity: createIdentity) else { return }; await mutateCategory(id: category?.id, unknownCreateIdentity: createIdentity, confirmed: { $0.name == name && $0.direction == direction && $0.icon == icon && $0.colorHex.uppercased() == color.uppercased() }) { [self] in if let category { return try await services.masterData.patchCategory(id: category.id, patch: .init(expectedVersion: category.version, name: name, direction: direction, icon: icon, colorHex: color)) } else { return try await services.masterData.createCategory(.init(name: name, direction: direction, icon: icon, colorHex: color)) } } }
    public func archiveOrRestoreCategory() async { guard canWrite("无法更改") else { return }; guard let category = selectedCategory else { return }; let archiving = category.archivedAt == nil; await mutateCategory(id: category.id, confirmed: { archiving ? $0.archivedAt != nil : $0.archivedAt == nil }) { [self] in archiving ? try await services.masterData.archiveCategory(id: category.id, expectedVersion: category.version) : try await services.masterData.restoreCategory(id: category.id, expectedVersion: category.version) } }
    public func saveMerchant() async {
        guard canWrite("无法保存") else { return }
        let aliases = merchantAliases.split(separator: "、").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let expectedName = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedName.isEmpty else { fieldIssues = [.init(code: "merchant_required", message: "请填写商户名称。", fieldPath: "merchant")]; return }
        // Capture the selected record before awaiting so an inspector selection change
        // cannot make the request and its readback predicate describe different input.
        let merchant = selectedMerchant
        let id = merchant?.id
        let createIdentity = merchant == nil ? identity(["merchant", expectedName] + aliases) : nil
        guard canSubmitCreate(section: .merchants, identity: createIdentity) else { return }
        do {
            let value: V15Merchant
            if let merchant {
                value = try await services.merchants.patch(id: merchant.id, patch: .init(expectedVersion: merchant.version, name: expectedName, aliases: aliases))
            } else {
                value = try await services.merchants.create(.init(name: expectedName, aliases: aliases))
            }
            receipt = "商户已由服务器确认：\(value.name) · v\(value.version)"
            if merchant == nil { unknownCreateLock = nil }
            await load()
        } catch let failure as V15Failure where V15LedgerCreateService.outcomeMayBeUnknown(failure) {
            if let id, let read = try? await services.merchants.get(id: id), read.name == expectedName, read.aliases == aliases {
                receipt = "已通过服务器读回确认商户：\(read.name) · v\(read.version)。未重发写入。"
            } else {
                if let createIdentity { await lockUnknownCreate(section: .merchants, identity: createIdentity); return }
                else { receipt = "响应未确认：已读回但未证明结果，未重发写入。" }
            }
            await load()
        } catch { apply(error) }
    }
    public func submitMerchantSearch() async { guard merchantSearch == committedMerchantSearch else { merchantPageGeneration &+= 1; merchantCursor = nil; merchantPageError = nil; isLoadingMerchants = false; committedMerchantSearch = merchantSearch; await load(); return }; await load() }
    public func loadNextMerchants() async { guard merchantSearch == committedMerchantSearch, let cursor = merchantCursor, !isLoadingMerchants else { return }; merchantPageGeneration &+= 1; let current = merchantPageGeneration; isLoadingMerchants = true; merchantPageError = nil; do { let page = try await services.merchants.list(query: committedMerchantSearch, cursor: cursor, limit: 50); guard current == merchantPageGeneration else { return }; merchants += page.items.filter { item in !merchants.contains(where: { $0.id == item.id }) }; merchantCursor = page.nextCursor } catch let failure as V15Failure { guard current == merchantPageGeneration else { return }; merchantPageError = failure } catch is CancellationError { guard current == merchantPageGeneration else { return }; merchantPageError = nil } catch { guard current == merchantPageGeneration else { return }; merchantPageError = .init(kind: .transport, message: "下一页商户读取失败。") }; guard current == merchantPageGeneration else { return }; isLoadingMerchants = false }
    public func loadMapping() async { guard let id = UUID(uuidString: mappingTransactionID) else { fieldIssues = [.init(code: "transaction_id_invalid", message: "请输入有效的交易 ID。", fieldPath: "transaction_id")]; return }; do { mapping = try await services.merchants.mapping(transactionID: id); receipt = mapping == nil ? "该交易尚未映射商户。" : "已读取服务器映射：\(mapping!.merchant.name)。" } catch { apply(error) } }
    public func confirmMapping() async { guard canWrite("无法提交更改") else { return }; guard let transactionID = UUID(uuidString: mappingTransactionID), let merchant = selectedMerchant else { fieldIssues = [.init(code: "mapping_required", message: "请选择商户并输入交易 ID。", fieldPath: "mapping")]; return }; let version = mapping?.mappingVersion; let identity = "confirm|\(transactionID)|\(merchant.id)|\(version.map(String.init) ?? "new")"; let key = idempotency.key(for: "merchant-mapping", payloadIdentity: identity); do { let result = try await services.merchants.confirmMapping(transactionID: transactionID, request: .init(merchantID: merchant.id, expectedMappingVersion: version), idempotencyKey: key); mapping = result.mapping; receipt = "映射已确认：\(result.action) · 交易 v\(result.transactionVersion)。"; idempotency.succeeded(scope: "merchant-mapping", payloadIdentity: identity) } catch let failure as V15Failure where V15LedgerCreateService.outcomeMayBeUnknown(failure) { if let read = try? await services.merchants.mapping(transactionID: transactionID), read.merchant.id == merchant.id { mapping = read; receipt = "已读回确认商户映射；未重复提交。"; idempotency.succeeded(scope: "merchant-mapping", payloadIdentity: identity) } else { receipt = "映射响应未确认；已读回但未证明结果，未重复提交。" } } catch { apply(error) } }
    public func releaseMapping() async { guard canWrite("无法提交更改") else { return }; guard let transactionID = UUID(uuidString: mappingTransactionID), let mapping else { return }; let identity = "release|\(transactionID)|\(mapping.mappingVersion)"; let key = idempotency.key(for: "merchant-release", payloadIdentity: identity); do { let result = try await services.merchants.releaseMapping(transactionID: transactionID, request: .init(expectedMappingVersion: mapping.mappingVersion), idempotencyKey: key); self.mapping = result.mapping; receipt = "映射已解除：交易 v\(result.transactionVersion)。"; idempotency.succeeded(scope: "merchant-release", payloadIdentity: identity) } catch let failure as V15Failure where V15LedgerCreateService.outcomeMayBeUnknown(failure) { do { let read = try await services.merchants.mapping(transactionID: transactionID); if read == nil { self.mapping = nil; receipt = "已读回确认映射解除；未重复提交。"; idempotency.succeeded(scope: "merchant-release", payloadIdentity: identity) } else { receipt = "解除响应未确认；未重复提交。" } } catch { receipt = "解除响应未确认且无法读回；未重复提交。" } } catch { apply(error) } }
    public func reorderAccounts(moving id: UUID, after target: UUID?) async { guard canWrite("无法提交更改") else { return }; guard selectedAccount?.archivedAt == nil, let revision = accountRevision else { receipt = "归档账户只能恢复，不能排序。"; return }; var ids = accounts.filter { $0.archivedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }.map(\.id); ids.removeAll { $0 == id }; if let target, let index = ids.firstIndex(of: target) { ids.insert(id, at: index + 1) } else { ids.insert(id, at: 0) }; do { _ = try await services.masterData.reorderAccounts(.init(orderedIDs: ids, expectedListRevision: revision)); receipt = "账户排序已由服务器确认。"; _ = await load() } catch { await reloadOnConflict(error) } }
    public func reorderCategories(moving id: UUID, after target: UUID?) async { guard canWrite("无法提交更改") else { return }; guard let category = selectedCategory ?? flatten(categories).first(where: { $0.id == id }) else { return }; guard category.archivedAt == nil else { receipt = "归档分类只能恢复，不能排序。"; return }; let key = category.direction + ":" + (category.parentID?.uuidString ?? "root"); do { let state = try await services.masterData.categoryOrderState(direction: V15CategoryDirection(rawValue: category.direction) ?? .unknown, parentID: category.parentID); categoryRevisions[key] = state.listRevision; var ids = state.items.map(\.id); ids.removeAll { $0 == id }; if let target, let index = ids.firstIndex(of: target) { ids.insert(id, at: index + 1) } else { ids.insert(id, at: 0) }; _ = try await services.masterData.reorderCategories(parentID: category.parentID, request: .init(orderedIDs: ids, expectedListRevision: state.listRevision)); receipt = "分类排序已由服务器确认。"; _ = await load() } catch { await reloadOnConflict(error) } }
    public func beginTransformFlow() { invalidatePreview(); transformMessage = nil; transformFailure = nil; transformFieldIssues = []; transformRequiresRepreview = false }
    public func previewMerge(targetID: UUID) async {
        guard let source = selectedCategory, let target = flatten(categories).first(where: { $0.id == targetID }) else { return }
        beginTransformFlow(); pendingTransformPreview = .merge(targetID)
        guard !isOffline else { recordTransformFailure(.init(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法读取合并预览。")); return }
        previewGeneration &+= 1; let current = previewGeneration
        do {
            let result = try await services.categories.mergePreview(sourceID: source.id, request: .init(targetID: target.id, sourceExpectedVersion: source.version, targetExpectedVersion: target.version))
            guard current == previewGeneration else { return }
            transformPreview = result
            childMappings = Dictionary(uniqueKeysWithValues: result.childMappingRequirements.compactMap { requirement in
                requirement.targetChildIDs.first.map { (requirement.sourceChildID, $0) }
            })
        } catch let failure as V15Failure {
            guard current == previewGeneration else { return }
            if failure.kind == .conflict { await recoverTransformConflict(failure) } else { recordTransformFailure(failure) }
        } catch {
            guard current == previewGeneration else { return }
            recordTransformFailure(.init(kind: .transport, message: "无法读取合并预览。"))
        }
    }
    public func invalidatePreview() { previewGeneration &+= 1; transformPreview = nil; splitPreview = nil; childMappings = [:]; splitAssignments = [:]; transformReceipt = nil; transformMessage = nil; transformFailure = nil; transformFieldIssues = []; transformRequiresRepreview = false; pendingTransformPreview = nil }
    public func commitMerge() async -> Bool { guard canWrite("无法提交合并"), !transformRequiresRepreview else { if transformRequiresRepreview { transformMessage = "此预览已失效，请重新读取预览后再提交。" }; return false }; guard let source = selectedCategory, let preview = transformPreview else { return false }; let mapping: [V15CategoryChildMapping] = preview.childMappingRequirements.compactMap { requirement in childMappings[requirement.sourceChildID].map { V15CategoryChildMapping(sourceChildID: requirement.sourceChildID, targetChildID: $0) } }; guard mapping.count == preview.childMappingRequirements.count else { transformFieldIssues = [.init(code: "child_mapping_required", message: "请为每个子分类指定归位目标。", fieldPath: "child_mappings")]; return false }; let identity = "\(preview.previewToken)|\(mapping)"; do { let result = try await services.categories.commitMerge(sourceID: source.id, request: .init(previewToken: preview.previewToken, childMappings: mapping), idempotencyKey: idempotency.key(for: "merge", payloadIdentity: identity)); idempotency.succeeded(scope: "merge", payloadIdentity: identity); transformReceipt = result; transformMessage = "合并已原子提交：重归类 \(result.reclassifiedTransactionCount) 笔。"; _ = await load(); return true } catch let failure as V15Failure where failure.kind == .conflict { await recoverTransformConflict(failure); return false } catch let failure as V15Failure { recordTransformFailure(failure); return false } catch { recordTransformFailure(.init(kind: .transport, message: "合并未完成，请重新决定。")); return false } }
    public func previewSplit() async {
        guard let root = selectedCategory else { return }
        beginTransformFlow(); pendingTransformPreview = .split
        guard !isOffline else { recordTransformFailure(.init(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法读取拆分预览。")); return }
        previewGeneration &+= 1; let current = previewGeneration
        let names = splitChildNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard names.count >= 2 else { transformFieldIssues = [.init(code: "split_children_required", message: "至少填写两个新子分类。", fieldPath: "split_children")]; return }
        do {
            let drafts = names.map { V15CategoryDraft(name: $0, direction: root.direction, parentID: root.id, icon: root.icon, colorHex: root.colorHex) }
            let result = try await services.categories.splitPreview(rootID: root.id, request: .init(rootExpectedVersion: root.version, children: drafts))
            guard current == previewGeneration else { return }
            splitPreview = result
            let fallback = result.childNames.first ?? names[0]
            splitAssignments = Dictionary(uniqueKeysWithValues: result.requiredTransactionIDs.map { ($0, fallback) })
        } catch let failure as V15Failure {
            guard current == previewGeneration else { return }
            if failure.kind == .conflict { await recoverTransformConflict(failure) } else { recordTransformFailure(failure) }
        } catch {
            guard current == previewGeneration else { return }
            recordTransformFailure(.init(kind: .transport, message: "无法读取拆分预览。"))
        }
    }
    public func commitSplit() async -> Bool { guard canWrite("无法提交拆分"), !transformRequiresRepreview else { if transformRequiresRepreview { transformMessage = "此预览已失效，请重新读取预览后再提交。" }; return false }; guard let root = selectedCategory, let preview = splitPreview else { return false }; let assignments = preview.requiredTransactionIDs.compactMap { id in splitAssignments[id].map { name in V15CategorySplitAssignment(transactionID: id, childName: name) } }; guard assignments.count == preview.requiredTransactionIDs.count else { transformFieldIssues = [.init(code: "split_assignment_required", message: "请逐笔指定归位子分类。", fieldPath: "assignments")]; return false }; let identity = "\(preview.previewToken)|\(assignments)"; do { let result = try await services.categories.commitSplit(rootID: root.id, request: .init(previewToken: preview.previewToken, assignments: assignments), idempotencyKey: idempotency.key(for: "split", payloadIdentity: identity)); idempotency.succeeded(scope: "split", payloadIdentity: identity); transformReceipt = result; transformMessage = "拆分已原子提交：重归类 \(result.reclassifiedTransactionCount) 笔。"; _ = await load(); return true } catch let failure as V15Failure where failure.kind == .conflict { await recoverTransformConflict(failure); return false } catch let failure as V15Failure { recordTransformFailure(failure); return false } catch { recordTransformFailure(.init(kind: .transport, message: "拆分未完成，请重新决定。")); return false } }
    private func mutate(id: UUID?, unknownCreateIdentity: String? = nil, confirmed: @escaping (V15AccountResponse) -> Bool, _ operation: () async throws -> V15AccountResponse) async {
        let previous = id.flatMap { target in accounts.first { $0.id == target } }
        do { let account = try await operation(); receipt = "账户已由服务器确认：\(account.name) · v\(account.version)"; if id == nil { unknownCreateLock = nil }; _ = await load()
        } catch let failure as V15Failure where failure.kind == .conflict { await recoverMutationConflict(failure, previousAccount: previous)
        } catch let failure as V15Failure where V15LedgerCreateService.outcomeMayBeUnknown(failure) { if let id, let account = try? await services.masterData.account(id: id), confirmed(account) { receipt = "已通过服务器读回确认：\(account.name) · v\(account.version)。未重发写入。"; _ = await load() } else if let unknownCreateIdentity { await lockUnknownCreate(section: .accounts, identity: unknownCreateIdentity) } else { _ = await load(); receipt = "响应未确认：读回事实未证明本次更改；已完整刷新，未重发写入。" } } catch { apply(error) }
    }
    private func mutateCategory(id: UUID?, unknownCreateIdentity: String? = nil, confirmed: @escaping (V15CategoryResponse) -> Bool, _ operation: () async throws -> V15CategoryResponse) async {
        let previous = id.flatMap { target in flatten(categories).first { $0.id == target } }
        do { let category = try await operation(); receipt = "分类已由服务器确认：\(category.name) · v\(category.version)"; if id == nil { unknownCreateLock = nil }; _ = await load()
        } catch let failure as V15Failure where failure.kind == .conflict { await recoverMutationConflict(failure, previousCategory: previous)
        } catch let failure as V15Failure where V15LedgerCreateService.outcomeMayBeUnknown(failure) { if let id, let category = try? await services.masterData.category(id: id), confirmed(category) { receipt = "已通过服务器读回确认：\(category.name) · v\(category.version)。未重发写入。"; _ = await load() } else if let unknownCreateIdentity { await lockUnknownCreate(section: .categories, identity: unknownCreateIdentity) } else { _ = await load(); receipt = "响应未确认：读回事实未证明本次更改；已完整刷新，未重发写入。" } } catch { apply(error) }
    }
    private func reloadOnConflict(_ error: Error) async { if let failure = error as? V15Failure, failure.kind == .conflict { await recoverMutationConflict(failure) } else { apply(error) } }
    public func resolveConflictByReload() async {
        guard conflict != nil else { return }
        if await load() { receipt = "已读取最新服务器事实；现在可以重新决定。" }
    }
    private func recoverMutationConflict(_ failure: V15Failure, previousAccount: V15AccountResponse? = nil, previousCategory: V15CategoryResponse? = nil) async {
        conflict = failure.conflict ?? .init(reloadPath: nil, latestRevision: nil, message: failure.message)
        fieldIssues = failure.fieldIssues; writesRequireExplicitReload = true
        if await load(preservingConflict: true) {
            if let previousAccount, let latest = accounts.first(where: { $0.id == previousAccount.id }) { conflictChanges = accountChanges(previous: previousAccount, current: latest) }
            if let previousCategory, let latest = flatten(categories).first(where: { $0.id == previousCategory.id }) { conflictChanges = categoryChanges(previous: previousCategory, current: latest) }
            receipt = "服务器版本已变化；已读取最新事实。请比较差异后显式重新读取以继续。"
        } else { receipt = "服务器版本已变化，但重新读取失败；写入已停止，请显式重新读取后再决定。" }
    }
    private func accountChanges(previous: V15AccountResponse, current: V15AccountResponse) -> [V15ConflictChange] {
        var changes: [V15ConflictChange] = []
        if previous.name != current.name { changes.append(.init(field: "账户名称", previousValue: previous.name, currentValue: current.name)) }
        if previous.openingBalanceMinor != current.openingBalanceMinor { changes.append(.init(field: "期初余额", previousValue: V15MoneyPresentation(minorUnits: previous.openingBalanceMinor, direction: .neutral).text, currentValue: V15MoneyPresentation(minorUnits: current.openingBalanceMinor, direction: .neutral).text)) }
        if previous.archivedAt != current.archivedAt { changes.append(.init(field: "归档状态", previousValue: previous.archivedAt == nil ? "可编辑" : "已归档", currentValue: current.archivedAt == nil ? "可编辑" : "已归档")) }
        if changes.isEmpty { changes.append(.init(field: "服务器版本", previousValue: "v\(previous.version)", currentValue: "v\(current.version)")) }
        return changes
    }
    private func categoryChanges(previous: V15CategoryResponse, current: V15CategoryResponse) -> [V15ConflictChange] {
        var changes: [V15ConflictChange] = []
        if previous.name != current.name { changes.append(.init(field: "分类名称", previousValue: previous.name, currentValue: current.name)) }
        if previous.icon != current.icon { changes.append(.init(field: "图标", previousValue: previous.icon, currentValue: current.icon)) }
        if previous.colorHex != current.colorHex { changes.append(.init(field: "颜色", previousValue: previous.colorHex, currentValue: current.colorHex)) }
        if previous.archivedAt != current.archivedAt { changes.append(.init(field: "归档状态", previousValue: previous.archivedAt == nil ? "可编辑" : "已归档", currentValue: current.archivedAt == nil ? "可编辑" : "已归档")) }
        if changes.isEmpty { changes.append(.init(field: "服务器版本", previousValue: "v\(previous.version)", currentValue: "v\(current.version)")) }
        return changes
    }
    private func recoverTransformConflict(_ failure: V15Failure) async {
        let pending = pendingTransformPreview
        invalidatePreview(); pendingTransformPreview = pending
        transformFailure = failure; transformFieldIssues = failure.fieldIssues; transformRequiresRepreview = true; writesRequireExplicitReload = true; conflict = failure.conflict
        if await load() { transformMessage = "服务器版本已变化，已重新读取完整列表；请重新读取预览后再提交。" }
        else { transformMessage = "服务器版本已变化，但重新读取失败；写入已停止，请显式重新读取后重新预览。" }
    }
    public func reloadAfterTransformConflict() async {
        writesRequireExplicitReload = true
        if await load() { transformFailure = nil; transformMessage = "已重新读取完整列表；请重新读取预览后再提交。"; transformRequiresRepreview = true }
        else { transformMessage = "重新读取失败；写入仍已停止，请稍后显式重新读取。"; transformRequiresRepreview = true }
    }
    public func retryTransformPreview() async {
        if writesRequireExplicitReload { await reloadAfterTransformConflict(); return }
        switch pendingTransformPreview {
        case .merge(let targetID): await previewMerge(targetID: targetID)
        case .split: await previewSplit()
        case nil: transformMessage = "请重新选择分类后读取预览。"
        }
    }
    private func recordTransformFailure(_ failure: V15Failure) { transformFailure = failure; transformFieldIssues = failure.fieldIssues; transformMessage = failure.message }
    public func clearCreditFieldsIfNeeded() { guard accountKind != .credit else { return }; creditLimit = ""; statementDay = ""; dueDay = ""; cycleMode = "statement_day_cutoff"; openingBalanceAsOfDate = ""; openingDueDate = "" }
    public func reloadAfterUnknownCreate() async {
        guard let lock = unknownCreateLock else { return }
        writesRequireExplicitReload = true
        if await load() {
            unknownCreateLock = .init(section: lock.section, payloadIdentity: lock.payloadIdentity, explicitlyReloaded: true)
            receipt = "已重新读取服务器事实；结果仍未确认。请重新决定后再提交，系统不会猜测已创建对象。"
        } else {
            writesRequireExplicitReload = true
            receipt = "重新读取失败；新建结果仍未确认，所有写入已停止。"
        }
    }
    private func lockUnknownCreate(section: Section, identity: String) async {
        unknownCreateLock = .init(section: section, payloadIdentity: identity)
        let refreshed = await load()
        if refreshed { receipt = "新建响应未确认；已读取服务器列表但无法安全定位对象。相同草稿不会再次提交，请显式重新读取后再确认或修改草稿。" }
        else { writesRequireExplicitReload = true; receipt = "新建响应未确认且重新读取失败；所有写入已停止，请显式重新读取后再决定。" }
    }
    private func canSubmitCreate(section: Section, identity: String?) -> Bool {
        guard let identity else { return true }
        guard let lock = unknownCreateLock, lock.section == section, lock.payloadIdentity == identity, !lock.explicitlyReloaded else { return true }
        receipt = "新建结果未确认；相同草稿不会再次提交。请先显式重新读取后再确认，或修改草稿形成新的提交意图。"
        return false
    }
    private var currentCreatePayloadIdentity: String? {
        switch selectedSection {
        case .accounts:
            guard selectedAccount == nil, let opening = CNYAmountParser.minorUnits(openingBalance) else { return nil }
            let isCredit = accountKind == .credit; let credit = isCredit && !creditLimit.isEmpty ? CNYAmountParser.minorUnits(creditLimit) : nil
            let statement = isCredit ? Int(statementDay) : nil; let due = isCredit ? Int(dueDay) : nil; let mode = isCredit ? cycleMode : nil
            return accountCreateIdentity(name: accountName, kind: accountKind, opening: opening, credit: credit, statement: statement, due: due, mode: mode, asOf: isCredit && opening > 0 ? openingBalanceAsOfDate : nil, dueDate: isCredit && opening > 0 ? openingDueDate : nil)
        case .categories: return selectedCategory == nil ? identity(["category", categoryName, categoryDirection.rawValue, categoryIcon, categoryColor]) : nil
        case .merchants:
            let aliases = merchantAliases.split(separator: "、").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return selectedMerchant == nil ? identity(["merchant", merchantName.trimmingCharacters(in: .whitespacesAndNewlines)] + aliases) : nil
        }
    }
    private func accountCreateIdentity(name: String, kind: V15AccountKind, opening: Int64, credit: Int64?, statement: Int?, due: Int?, mode: String?, asOf: String?, dueDate: String?) -> String { identity(["account", name, kind.rawValue, String(opening), credit.map(String.init) ?? "∅", statement.map(String.init) ?? "∅", due.map(String.init) ?? "∅", mode ?? "∅", asOf ?? "∅", dueDate ?? "∅"]) }
    private func identity(_ fields: [String]) -> String { fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|") }
    private func canWrite(_ action: String) -> Bool { if isOffline { receipt = "离线快照仅可查看，\(action)。"; return false }; if writesRequireExplicitReload { receipt = unknownCreateLock == nil ? "上次冲突后的重新读取未完成，\(action)；请显式重新读取后再决定。" : "新建结果未确认且重新读取失败，\(action)；请显式重新读取后再决定。"; return false }; return true }
    public static func reorderHint(canMove: Bool, down: Bool) -> String { if canMove { return down ? "⌘⌥↓ 下移一位" : "⌘⌥↑ 上移一位" }; return down ? "已到末位，不能下移。" : "已到首位，不能上移。" }
    private func apply(_ error: Error) { if let failure = error as? V15Failure { fieldIssues = failure.fieldIssues; conflict = failure.conflict; receipt = failure.kind == .conflict ? "服务器版本已变化；写入已停止，请重新读取后再决定。" : failure.message } else { receipt = "操作未完成，请重新读取后再决定。" } }
    private func flatten(_ items: [V15CategoryResponse]) -> [V15CategoryResponse] { items + items.flatMap { flatten($0.children) } }
}

@MainActor @Observable
public final class V15SettingsOverviewModel {
    public enum Phase: Equatable { case idle, loading, loaded, offline(Date), failed(V15Failure) }
    public private(set) var phase: Phase = .idle
    public private(set) var accounts: [V15AccountResponse] = []
    public private(set) var categories: [V15CategoryResponse] = []
    public private(set) var claims: [V15ReimbursementClaim] = []
    public private(set) var transactions: [V15Transaction] = []
    public private(set) var claimsIncomplete = false
    public private(set) var transactionsIncomplete = false
    public private(set) var aiSettings: V15AISettings?
    public private(set) var providerSettings: V15AIProviderSettings?
    public private(set) var qualityMetrics: V15AIQualityMetrics?
    public private(set) var failures: [String: V15Failure] = [:]
    public private(set) var restoringID: UUID?
    public private(set) var restoreFailure: V15Failure?
    private let services: V15Services
    private let offlineSnapshotProvider: @MainActor @Sendable () -> Date?
    private var generation: UInt64 = 0

    public init(services: V15Services, offlineSnapshotAt: Date? = nil) {
        self.services = services
        self.offlineSnapshotProvider = { offlineSnapshotAt ?? services.offlineSnapshotAt }
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider() }
    public var archivedAccounts: [V15AccountResponse] { accounts.filter { $0.archivedAt != nil } }
    public var archivedCategories: [V15CategoryResponse] { flatten(categories).filter { $0.archivedAt != nil } }
    public var archivedClaims: [V15ReimbursementClaim] { claims.filter { $0.archivedAt != nil } }
    public var voidedClaims: [V15ReimbursementClaim] { claims.filter { $0.voidedAt != nil && $0.archivedAt == nil } }
    public var voidedTransactions: [V15Transaction] { transactions.filter { $0.voidedAt != nil } }
    public var archiveItemCount: Int { archivedAccounts.count + archivedCategories.count + archivedClaims.count + voidedClaims.count + voidedTransactions.count }
    public var activeAccountCount: Int { accounts.filter { $0.archivedAt == nil }.count }
    public var activeCategoryCount: Int { flatten(categories).filter { $0.archivedAt == nil }.count }
    public var qualityTotal: Int { qualityMetrics?.rows.reduce(0) { $0 + $1.total } ?? 0 }
    public var qualityPending: Int { qualityMetrics?.rows.reduce(0) { $0 + $1.pending } ?? 0 }
    public var providerHost: String? { providerSettings?.baseURL.flatMap { URL(string: $0)?.host } }

    public func load() async {
        generation &+= 1
        let current = generation
        failures = [:]; restoreFailure = nil; clearFacts()
        guard let snapshot = offlineSnapshotAt else {
            phase = .loading
            let masterData = services.masterData
            let reimbursements = services.reimbursements
            let ledger = services.ledger
            let ai = services.ai
            async let accountResult = Self.capture { try await masterData.accounts(includeArchived: true) }
            async let categoryResult = Self.capture { try await masterData.categories(includeArchived: true) }
            async let claimResult = Self.capture { try await reimbursements.claims(includeArchived: true, includeVoided: true, limit: 100) }
            async let transactionResult = Self.capture { try await ledger.list(.init(limit: 100, includeVoided: true)) }
            async let aiResult = Self.capture { try await ai.settings() }
            async let providerResult = Self.capture { try await ai.providerSettings() }
            async let qualityResult = Self.capture { try await ai.qualityMetrics() }
            let results = await (accountResult, categoryResult, claimResult, transactionResult, aiResult, providerResult, qualityResult)
            guard current == generation else { return }
            if Task.isCancelled { phase = .idle; return }
            apply(results.0, key: "accounts") { accounts = $0 }
            apply(results.1, key: "categories") { categories = $0 }
            apply(results.2, key: "claims") { claims = $0.items; claimsIncomplete = $0.nextCursor != nil }
            apply(results.3, key: "transactions") { transactions = $0.items; transactionsIncomplete = $0.nextCursor != nil }
            apply(results.4, key: "ai_settings") { aiSettings = $0 }
            apply(results.5, key: "provider") { providerSettings = $0 }
            apply(results.6, key: "quality") { qualityMetrics = $0 }
            if accounts.isEmpty && categories.isEmpty && claims.isEmpty && transactions.isEmpty && aiSettings == nil && providerSettings == nil && qualityMetrics == nil {
                phase = .failed(failures.values.first ?? .init(kind: .transport, message: "无法读取设置事实。"))
            } else { phase = .loaded }
            return
        }
        phase = .offline(snapshot)
    }

    public func restoreAccount(_ item: V15AccountResponse) async { await restore(id: item.id) { try await services.masterData.restoreAccount(id: item.id, expectedVersion: item.version) } }
    public func restoreCategory(_ item: V15CategoryResponse) async { await restore(id: item.id) { try await services.masterData.restoreCategory(id: item.id, expectedVersion: item.version) } }
    public func unarchiveClaim(_ item: V15ReimbursementClaim) async { await restore(id: item.id) { try await services.reimbursements.unarchive(claimID: item.id, request: .init(expectedVersion: item.version)) } }
    public func restoreClaim(_ item: V15ReimbursementClaim) async { await restore(id: item.id) { try await services.reimbursements.restoreClaim(claimID: item.id, request: .init(expectedVersion: item.version)) } }
    public func restoreTransaction(_ item: V15Transaction) async { await restore(id: item.id) { try await services.ledger.restore(transactionID: item.id, expectedVersion: item.version) } }
    public func invalidate() { generation &+= 1; phase = .idle }

    private func restore<Value: Sendable>(id: UUID, operation: () async throws -> Value) async {
        guard offlineSnapshotAt == nil, restoringID == nil else { return }
        restoringID = id; restoreFailure = nil
        do { _ = try await operation(); restoringID = nil; await load() }
        catch let failure as V15Failure { restoringID = nil; restoreFailure = failure }
        catch { restoringID = nil; restoreFailure = .init(kind: .transport, message: "恢复未完成，请重新读取后再决定。") }
    }
    private func apply<Value>(_ result: Result<Value, V15Failure>, key: String, success: (Value) -> Void) {
        switch result { case .success(let value): success(value); case .failure(let failure): failures[key] = failure }
    }
    private func clearFacts() {
        accounts = []; categories = []; claims = []; transactions = []
        claimsIncomplete = false; transactionsIncomplete = false
        aiSettings = nil; providerSettings = nil; qualityMetrics = nil
    }
    private func flatten(_ items: [V15CategoryResponse]) -> [V15CategoryResponse] { items + items.flatMap { flatten($0.children) } }
    private nonisolated static func capture<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Result<Value, V15Failure> {
        do { return .success(try await operation()) }
        catch is CancellationError { return .failure(.init(kind: .cancelled, message: "请求已取消。")) }
        catch let failure as V15Failure { return .failure(failure) }
        catch { return .failure(.init(kind: .transport, message: "无法读取设置事实。")) }
    }
}
