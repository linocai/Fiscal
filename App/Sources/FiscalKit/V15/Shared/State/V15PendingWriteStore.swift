import Foundation
import Observation

/// Encrypted durable journal. Only explicit offline-safe writes may be queued.
/// In-flight ownership survives editors, cancellation and process restarts.
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
        case repayment
        case creditPayoff, creditPayoffReverse
        case statementProviderAttempt
        case statementConfirmation
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
        public let payload: JSONValue?
        public let resourceID: UUID?
        public let scope: String?
        public let schemaVersion: Int?
        public var idempotencyKey: UUID { id }
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
            payload: JSONValue? = nil,
            resourceID: UUID? = nil,
            scope: String? = nil,
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
            self.payload = payload; self.resourceID = resourceID; self.scope = scope; self.schemaVersion = 1
            self.status = status
            self.message = message
        }
    }

    public private(set) var items: [Item]
    public private(set) var lastSyncReceipt: String?
    public var count: Int { items.count }
    public var requiresDecisionCount: Int { items.filter { $0.status == .requiresDecision || $0.status == .outcomeUnknown }.count }

    public private(set) var storageFailure: V15Failure?
    public let scope: String
    private let persistence: V15JournalPersistence?
    private var replaying = false

    public init(defaults: UserDefaults? = nil, storageKey: String = "fiscal.v151.pending-writes", scope: String = "fixture", persistence: V15JournalPersistence? = nil) {
        self.scope = scope
        self.persistence = persistence ?? (defaults == nil ? nil : .encrypted(scope: scope))
        items = []
        do {
            if let data = try self.persistence?.read() {
                let decoded = try JSONDecoder().decode([Item].self, from: data)
                guard decoded.allSatisfy({ $0.scope == nil || $0.scope == scope }) else { throw CocoaError(.fileReadCorruptFile) }
                items = decoded
            }
            if let legacy = defaults?.data(forKey: storageKey) {
                let old = try JSONDecoder().decode([Item].self, from: legacy)
                for item in old where !items.contains(where: { $0.id == item.id }) {
                    items.append(Item(id: item.id, kind: item.kind, createdAt: item.createdAt, title: item.title, amountMinor: item.amountMinor, createRequest: item.createRequest, transactionID: item.transactionID, replaceRequest: item.replaceRequest, payload: item.payload, resourceID: item.resourceID, scope: scope, status: item.status, message: item.message))
                }
                guard let persistence = self.persistence else { throw CocoaError(.fileWriteUnknown) }
                let encoded = try JSONEncoder().encode(items)
                try persistence.write(encoded)
                guard try persistence.read() == encoded else { throw CocoaError(.fileReadCorruptFile) }
                defaults?.removeObject(forKey: storageKey)
            }
            items = items.map { item in var value = item; if value.status == .syncing { value.status = .outcomeUnknown }; return value }
            if !items.isEmpty { try persist(items) }
        } catch { storageFailure = Self.storageError }
    }

    public func prepare<Request: Encodable>(kind: Kind, title: String, request: Request, idempotencyKey: UUID, resourceID: UUID? = nil) throws -> UUID {
        try prepare(kind: kind, title: title, payload: V15BodyEncoder.encode(request), idempotencyKey: idempotencyKey, resourceID: resourceID)
    }

    public func prepare(kind: Kind, title: String, payload: JSONValue, idempotencyKey: UUID, resourceID: UUID? = nil) throws -> UUID {
        try ensureStorage()
        if let existing = items.first(where: { $0.id == idempotencyKey }) {
            guard existing.kind == kind, existing.payload == payload, existing.resourceID == resourceID else { throw invalidPayload() }
            return existing.id
        }
        let item = Item(id: idempotencyKey, kind: kind, title: title, amountMinor: nil, payload: payload, resourceID: resourceID, scope: scope, status: .outcomeUnknown)
        try replaceItems(items + [item])
        return item.id
    }

    public func markInFlight(_ id: UUID) throws { try change(id, status: .syncing, message: nil) }
    public func markUnknown(_ id: UUID, message: String = "结果暂时不明，请读取原操作回执。") { update(id, status: .outcomeUnknown, message: message) }
    public func complete(_ id: UUID) throws { try replaceItems(items.filter { $0.id != id }) }
    public func item(_ id: UUID) -> Item? { items.first { $0.id == id } }
    public func ensureStorage() throws { if let storageFailure { throw storageFailure } }

    @discardableResult
    public func enqueueCreate(_ request: V15TransactionCreateRequest) -> UUID {
        let item = Item(
            kind: .transactionCreate,
            title: request.title,
            amountMinor: request.amountMinor,
            createRequest: request,
            scope: scope
        )
        do { try replaceItems(items + [item]) } catch { storageFailure = Self.storageError }
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
            replaceRequest: request,
            scope: scope
        )
        do { try replaceItems(items + [item]) } catch { storageFailure = Self.storageError }
        return item.id
    }

    public func remove(_ id: UUID) {
        guard let item = item(id), item.status != .syncing, item.status != .outcomeUnknown else { return }
        do { try complete(id) } catch { storageFailure = Self.storageError }
    }

    public func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .failed else { return }
        items[index].status = .queued
        items[index].message = nil
        do { try persist(items) } catch { storageFailure = Self.storageError }
    }

    public func replay(using services: V15Services) async {
        guard !replaying, storageFailure == nil, services.offlineSnapshotAt == nil else { return }
        replaying = true
        defer { replaying = false }
        let queuedIDs = items.filter { $0.status == .queued || $0.status == .outcomeUnknown }.map(\.id)
        var succeeded = 0
        for id in queuedIDs {
            guard services.offlineSnapshotAt == nil,
                  let index = items.firstIndex(where: { $0.id == id }),
                  items[index].status == .queued || items[index].status == .outcomeUnknown else { continue }
            if items[index].status == .outcomeUnknown {
                if await recover(id, using: services) { succeeded += 1 }
                continue
            }
            do { try markInFlight(id) } catch { break }
            if await replayItem(id, using: services) { succeeded += 1 }
        }
        guard succeeded > 0 else { return }
        let remaining = items.count
        lastSyncReceipt = remaining == 0
            ? "已同步 \(succeeded) 项"
            : "已同步 \(succeeded) 项 · \(remaining) 项需要处理"
    }

    public func dismissReceipt() { lastSyncReceipt = nil }

    private func replayItem(_ id: UUID, using services: V15Services, preservingUnknown: Bool = false) async -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            switch item.kind {
            case .transactionCreate:
                let request = try item.createRequest ?? item.payload.map { try V15BodyEncoder.decode(V15TransactionCreateRequest.self, from: $0) }
                guard let request else { throw invalidPayload() }
                _ = try await services.ledger.create(request, idempotencyKey: item.id)
            case .categoryReplace:
                guard let transactionID = item.transactionID, let request = item.replaceRequest else { throw invalidPayload() }
                _ = try await services.ledger.replace(transactionID: transactionID, request: request)
            case .repayment:
                guard let payload = item.payload else { throw invalidPayload() }
                let request = try V15BodyEncoder.decode(V15JournalRepayment.self, from: payload)
                _ = try await services.actions.commitRepayment(previewToken: request.previewToken, idempotencyKey: item.id)
            case .creditPayoff, .creditPayoffReverse, .statementProviderAttempt, .statementConfirmation:
                markUnknown(id, message: "请回到账单导入继续恢复此操作。")
                return false
            }
            try complete(id)
            await services.refreshAfterRecoveredWrite()
            return true
        } catch let failure as V15Failure {
            if preservingUnknown { markUnknown(id, message: failure.message) }
            else if failure.kind == .conflict {
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
            let current = try await services.ledger.get(transactionID: transactionID, readCachePolicy: .reloadIgnoringCache)
            if current.categoryID == expectedCategory {
                try complete(item.id)
                await services.refreshAfterRecoveredWrite()
            } else if current.version == request.expectedVersion {
                update(item.id, status: .queued, message: "原修改尚未执行，可安全重试。")
            } else {
                update(item.id, status: .requiresDecision, message: "交易已经更新，需要重新决定分类。")
            }
        } catch {
            update(item.id, status: .outcomeUnknown, message: "暂时无法读取最新数据，需要稍后核对。")
        }
    }

    public func recover(_ id: UUID, using services: V15Services) async -> Bool {
        guard let item = item(id), storageFailure == nil else { return false }
        do {
            switch item.kind {
            case .transactionCreate: _ = try await services.ledger.receipt(idempotencyKey: item.id)
            case .repayment: _ = try await services.actions.receipt(idempotencyKey: item.id)
            case .categoryReplace: await reconcileUnknown(item, services: services); return self.item(id) == nil
            case .creditPayoff, .creditPayoffReverse, .statementProviderAttempt, .statementConfirmation: return false
            }
            try complete(id)
            await services.refreshAfterRecoveredWrite()
            return true
        } catch { markUnknown(id); return false }
    }

    /// Explicit replay preserves the serialized original request and key. A missing
    /// receipt is never evidence that the first request did not execute.
    public func replayUnknown(_ id: UUID, using services: V15Services) async -> Bool {
        guard services.offlineSnapshotAt == nil, let item = item(id), item.status == .outcomeUnknown else { return false }
        if await recover(id, using: services) { return true }
        guard let latest = self.item(id), latest.status == .outcomeUnknown || latest.status == .queued else { return false }
        do { try markInFlight(id) } catch { return false }
        return await replayItem(id, using: services, preservingUnknown: true)
    }

    private func update(_ id: UUID, status: Status, message: String) {
        do { try change(id, status: status, message: message) } catch { storageFailure = Self.storageError }
    }
    private func change(_ id: UUID, status: Status, message: String?) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw invalidPayload() }
        var changed = items; changed[index].status = status; changed[index].message = message
        try replaceItems(changed)
    }
    private func replaceItems(_ value: [Item]) throws {
        try ensureStorage()
        do { try persist(value); items = value }
        catch { storageFailure = Self.storageError; throw Self.storageError }
    }
    private func persist(_ value: [Item]) throws { try persistence?.write(JSONEncoder().encode(value)) }
    private static var storageError: V15Failure { .init(kind: .transport, code: "write_journal_unavailable", message: "安全写入记录无法保存或读取，请恢复本地存储；未确认请求会保留，不会自动重发。") }
    private func invalidPayload() -> V15Failure { .init(kind: .decoding, code: "pending_write_invalid", message: "本地待处理请求无法读取，请保留记录并恢复存储。") }
}

struct V15JournalRepayment: Codable { let previewToken: UUID; enum CodingKeys: String, CodingKey { case previewToken = "preview_token" } }
