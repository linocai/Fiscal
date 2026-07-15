import Foundation
import Observation

public enum MasterDataPhase: Sendable, Equatable {
    case idle, loading, loaded, empty, unauthorized, offline, failed
}

@MainActor
@Observable
public final class AccountsModel {
    public private(set) var accounts: [AccountDTO] = []
    public private(set) var phase: MasterDataPhase = .idle
    public private(set) var message: String?
    public private(set) var conflictDetected = false
    public var includeArchived = false
    public private(set) var isMutating = false
    private let repository: any AccountRepository

    public init(repository: any AccountRepository) { self.repository = repository }

    public func load() async {
        phase = .loading; message = nil; conflictDetected = false
        do {
            accounts = try await repository.list(includeArchived: includeArchived)
            phase = accounts.isEmpty ? .empty : .loaded
        } catch where Task.isCancelled { phase = .idle }
        catch let error as URLError where error.code == .cancelled { phase = .idle }
        catch { apply(error) }
    }

    public func save(draft: AccountDraft, editing: AccountDTO?) async -> Bool {
        if let validation = Self.validate(draft) { message = validation; return false }
        isMutating = true; defer { isMutating = false }
        do {
            if let editing { _ = try await repository.update(id: editing.id, version: editing.version, draft: draft) }
            else { _ = try await repository.create(draft) }
            await load(); return true
        } catch { apply(error); return false }
    }

    public func archiveOrRestore(_ account: AccountDTO) async {
        isMutating = true; defer { isMutating = false }
        do { if account.archivedAt == nil { _ = try await repository.archive(account) } else { _ = try await repository.restore(account) }; await load() }
        catch { apply(error) }
    }

    public func delete(_ account: AccountDTO) async {
        isMutating = true; defer { isMutating = false }
        do { try await repository.delete(account); await load() } catch { apply(error) }
    }
    public func clearConflict() { conflictDetected = false }

    public func move(_ account: AccountDTO, by offset: Int) async {
        var active = accounts.filter { $0.archivedAt == nil }
        guard let index = active.firstIndex(where: { $0.id == account.id }) else { return }
        let destination = index + offset
        guard active.indices.contains(destination) else { return }
        active.swapAt(index, destination); isMutating = true; defer { isMutating = false }
        do { _ = try await repository.reorder(ids: active.map(\.id)); await load() } catch { apply(error) }
    }

    public static func validate(_ draft: AccountDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 80 { return "账户名称需要 1–80 个字符。" }
        if !draft.lastFour.isEmpty && (draft.lastFour.count != 4 || draft.lastFour.contains(where: { !$0.isASCII || !$0.isNumber })) { return "尾号必须是 4 位数字。" }
        if draft.institution.count > 80 { return "机构名称不能超过 80 个字符。" }
        if draft.kind == .credit {
            guard let limit = draft.creditLimitMinor, limit > 0 else { return "信用账户必须填写正数额度。" }
            guard let statement = draft.statementDay, (1...28).contains(statement), let due = draft.dueDay, (1...28).contains(due) else { return "账单日和还款日必须在 1–28 日。" }
            if draft.openingBalanceMinor < 0 || draft.openingBalanceMinor > limit { return "信用欠款需在 0 与额度之间。" }
        }
        return nil
    }

    private func apply(_ error: Error) {
        conflictDetected = false
        guard let api = error as? FiscalAPIError else { phase = .failed; message = error.localizedDescription; return }
        message = api.displayMessage
        switch api { case .unauthorized: phase = .unauthorized; case .transport: phase = .offline; case .domain(_, let detail) where detail.code == "resource_version_conflict": phase = .failed; conflictDetected = true; default: phase = .failed }
    }
}

@MainActor
@Observable
public final class CategoriesModel {
    public private(set) var categories: [CategoryDTO] = []
    public private(set) var phase: MasterDataPhase = .idle
    public private(set) var message: String?
    public private(set) var conflictDetected = false
    public var includeArchived = false
    public var direction: CategoryDirection?
    public private(set) var isMutating = false
    private let repository: any CategoryRepository

    public init(repository: any CategoryRepository) { self.repository = repository }
    public var flattened: [CategoryDTO] { categories.flatMap { [$0] + $0.children } }

    public func load() async {
        phase = .loading; message = nil; conflictDetected = false
        do { categories = try await repository.list(direction: direction, includeArchived: includeArchived); phase = categories.isEmpty ? .empty : .loaded }
        catch where Task.isCancelled { phase = .idle }
        catch let error as URLError where error.code == .cancelled { phase = .idle }
        catch { apply(error) }
    }

    public func save(draft: CategoryDraft, editing: CategoryDTO?) async -> Bool {
        if let validation = Self.validate(draft) { message = validation; return false }
        isMutating = true; defer { isMutating = false }
        do {
            if let editing { _ = try await repository.update(id: editing.id, version: editing.version, draft: draft) }
            else { _ = try await repository.create(draft) }
            await load(); return true
        } catch { apply(error); return false }
    }

    public func archiveOrRestore(_ category: CategoryDTO) async { await mutate { if category.archivedAt == nil { _ = try await self.repository.archive(category) } else { _ = try await self.repository.restore(category) } } }
    public func delete(_ category: CategoryDTO) async { await mutate { try await self.repository.delete(category) } }
    public func merge(source: CategoryDTO, target: CategoryDTO) async -> Bool {
        await mutate { _ = try await self.repository.merge(source: source, target: target) }
    }
    public func split(root: CategoryDTO, children: [CategoryDraft]) async -> Bool {
        guard children.count >= 2, children.allSatisfy({ Self.validate($0) == nil }) else { message = "拆分至少需要两个有效子分类。"; return false }
        return await mutate { _ = try await self.repository.split(root: root, children: children) }
    }
    public func clearConflict() { conflictDetected = false }

    public func move(_ category: CategoryDTO, by offset: Int) async {
        let siblings = category.parentID == nil ? categories.filter { $0.archivedAt == nil && $0.direction == category.direction } : categories.first(where: { $0.id == category.parentID })?.children.filter { $0.archivedAt == nil } ?? []
        guard let index = siblings.firstIndex(where: { $0.id == category.id }) else { return }
        let destination = index + offset
        guard siblings.indices.contains(destination) else { return }
        var reordered = siblings; reordered.swapAt(index, destination); isMutating = true; defer { isMutating = false }
        do { _ = try await repository.reorder(ids: reordered.map(\.id), parentID: category.parentID); await load() } catch { apply(error) }
    }

    public static func validate(_ draft: CategoryDraft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 80 { return "分类名称需要 1–80 个字符。" }
        if draft.icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.icon.count > 80 { return "图标名称需要 1–80 个字符。" }
        if draft.colorHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { return "颜色必须是 #RRGGBB。" }
        for values in [draft.aliases, draft.examples] {
            if values.count > 20 || values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.count > 40 }) { return "别名和示例最多各 20 条，每条 1–40 个字符。" }
            if Set(values.map { $0.lowercased() }).count != values.count { return "别名和示例不能重复。" }
        }
        return nil
    }

    @discardableResult
    private func mutate(_ operation: () async throws -> Void) async -> Bool {
        isMutating = true; defer { isMutating = false }
        do { try await operation(); await load(); return true } catch { apply(error); return false }
    }
    private func apply(_ error: Error) {
        conflictDetected = false
        guard let api = error as? FiscalAPIError else { phase = .failed; message = error.localizedDescription; return }
        message = api.displayMessage
        switch api { case .unauthorized: phase = .unauthorized; case .transport: phase = .offline; case .domain(_, let detail) where detail.code == "resource_version_conflict": phase = .failed; conflictDetected = true; default: phase = .failed }
    }
}
