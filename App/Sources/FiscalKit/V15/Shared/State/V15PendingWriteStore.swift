import Foundation
import Observation

/// Client-owned outbox for the small, explicitly allowlisted set of writes
/// that can be decided without a server preview. Production persists it in
/// UserDefaults; fixture services receive an in-memory instance.
@MainActor @Observable
public final class V15PendingWriteStore {
    public enum Status: String, Codable, Sendable, Equatable {
        case queued
        case syncing
        case requiresDecision
        case outcomeUnknown
        case failed
    }

    public enum Kind: String, Codable, Sendable, Equatable {
        case transactionCreate
        case categoryReplace
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let kind: Kind
        public let createdAt: Date
        public let title: String
        public let amountMinor: Int64?
        public let createRequest: V15TransactionCreateRequest?
        public let transactionID: UUID?
        public let replaceRequest: V15TransactionReplaceRequest?
        public var status: Status
        public var message: String?

        fileprivate init(
            id: UUID = UUID(),
            kind: Kind,
            createdAt: Date = Date(),
            title: String,
            amountMinor: Int64?,
            createRequest: V15TransactionCreateRequest? = nil,
            transactionID: UUID? = nil,
            replaceRequest: V15TransactionReplaceRequest? = nil,
            status: Status = .queued,
            message: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.createdAt = createdAt
            self.title = title
            self.amountMinor = amountMinor
            self.createRequest = createRequest
            self.transactionID = transactionID
            self.replaceRequest = replaceRequest
            self.status = status
            self.message = message
        }
    }

    public private(set) var items: [Item]
    public private(set) var lastSyncReceipt: String?
    public var count: Int { items.count }
    public var requiresDecisionCount: Int { items.filter { $0.status == .requiresDecision || $0.status == .outcomeUnknown }.count }

    private let defaults: UserDefaults?
    private let storageKey: String
    private var replaying = false

    public init(defaults: UserDefaults? = nil, storageKey: String = "fiscal.v151.pending-writes") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults?.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded.map { item in
                var recovered = item
                if recovered.status == .syncing { recovered.status = .queued }
                return recovered
            }
        } else {
            items = []
        }
    }

    @discardableResult
    public func enqueueCreate(_ request: V15TransactionCreateRequest) -> UUID {
        let item = Item(
            kind: .transactionCreate,
            title: request.title,
            amountMinor: request.amountMinor,
            createRequest: request
        )
        items.append(item)
        persist()
        return item.id
    }

    @discardableResult
    public func enqueueCategory(
        transactionID: UUID,
        transactionTitle: String,
        amountMinor: Int64,
        request: V15TransactionReplaceRequest
    ) -> UUID {
        let item = Item(
            kind: .categoryReplace,
            title: "分类 · \(transactionTitle)",
            amountMinor: amountMinor,
            transactionID: transactionID,
            replaceRequest: request
        )
        items.append(item)
        persist()
        return item.id
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .failed else { return }
        items[index].status = .queued
        items[index].message = nil
        persist()
    }

    public func replay(using services: V15Services) async {
        guard !replaying, services.offlineSnapshotAt == nil else { return }
        replaying = true
        defer { replaying = false }
        let queuedIDs = items.filter { $0.status == .queued }.map(\.id)
        var succeeded = 0
        for id in queuedIDs {
            guard services.offlineSnapshotAt == nil,
                  let index = items.firstIndex(where: { $0.id == id }),
                  items[index].status == .queued else { break }
            items[index].status = .syncing
            persist()
            if await replayItem(id, using: services) { succeeded += 1 }
        }
        guard succeeded > 0 else { return }
        let remaining = items.count
        lastSyncReceipt = remaining == 0
            ? "已同步 \(succeeded) 项"
            : "已同步 \(succeeded) 项 · \(remaining) 项需要处理"
    }

    public func dismissReceipt() { lastSyncReceipt = nil }

    private func replayItem(_ id: UUID, using services: V15Services) async -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            switch item.kind {
            case .transactionCreate:
                guard let request = item.createRequest else { throw invalidPayload() }
                _ = try await services.ledger.create(request, idempotencyKey: item.id)
            case .categoryReplace:
                guard let transactionID = item.transactionID, let request = item.replaceRequest else { throw invalidPayload() }
                _ = try await services.ledger.replace(transactionID: transactionID, request: request)
            }
            remove(id)
            return true
        } catch let failure as V15Failure {
            if failure.kind == .conflict {
                update(id, status: .requiresDecision, message: "数据已经更新，需要重新决定。")
            } else if V15LedgerCreateService.outcomeMayBeUnknown(failure) {
                await reconcileUnknown(item, services: services)
            } else {
                update(id, status: .failed, message: failure.message)
            }
        } catch {
            await reconcileUnknown(item, services: services)
        }
        return false
    }

    private func reconcileUnknown(_ item: Item, services: V15Services) async {
        guard item.kind == .categoryReplace,
              let transactionID = item.transactionID,
              let request = item.replaceRequest else {
            update(item.id, status: .outcomeUnknown, message: "操作结果暂时不明；系统不会自动重复操作。")
            return
        }
        let expectedCategory = request.categoryID
        do {
            let current = try await services.ledger.get(transactionID: transactionID)
            if current.categoryID == expectedCategory {
                remove(item.id)
            } else {
                update(item.id, status: .outcomeUnknown, message: "当前分类与待提交值不同，需要重新决定。")
            }
        } catch {
            update(item.id, status: .outcomeUnknown, message: "暂时无法读取最新数据，需要稍后核对。")
        }
    }

    private func update(_ id: UUID, status: Status, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].message = message
        persist()
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func invalidPayload() -> V15Failure {
        .init(kind: .decoding, code: "pending_write_invalid", message: "本地待同步内容无法读取，请移除后重新录入。")
    }
}
