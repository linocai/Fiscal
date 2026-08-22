import Foundation

public enum V15ReadCachePolicy: Sendable, Equatable {
    /// Ordinary reads retain the shared transport's existing cache behaviour.
    case standard
    /// A revision-conflict recovery must reach the server rather than reuse a
    /// potentially stale GET entry.
    case reloadIgnoringCache
}

struct V15Request: Sendable, Equatable {
    let path: String
    let method: String
    let query: [URLQueryItem]
    let headers: [String: String]
    let readCachePolicy: V15ReadCachePolicy
    init(path: String, method: String = "GET", query: [URLQueryItem] = [], headers: [String: String] = [:], readCachePolicy: V15ReadCachePolicy = .standard) {
        self.path = path; self.method = method; self.query = query; self.headers = headers; self.readCachePolicy = readCachePolicy
    }
}

/// The clean-room boundary. V15 feature code depends on this protocol, never on
/// legacy repositories or their DTOs.
protocol V15Transporting: Sendable {
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response
    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data
    func fetchArtifactResponse(_ request: V15Request, accept: String) async throws -> V15ArtifactTransfer
    func fetchArtifactResponse(_ request: V15Request, accept: String, body: JSONValue?) async throws -> V15ArtifactTransfer
}

extension V15Transporting {
    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws {
        let _: JSONValue = try await send(request, body: body)
    }
    func fetchArtifactResponse(_ request: V15Request, accept: String) async throws -> V15ArtifactTransfer {
        // Existing feature fixtures have no artifact metadata. They must not
        // accidentally become valid report exports.
        let data = try await fetchArtifact(request, accept: accept)
        return .init(data: data, headers: [:])
    }
    func fetchArtifactResponse(_ request: V15Request, accept: String, body: JSONValue?) async throws -> V15ArtifactTransfer {
        // Fixture transports that only model report exports cannot
        // accidentally succeed for the Archive POST contract.
        guard request.method == "GET", body == nil else {
            throw V15Failure(kind: .decoding, code: "artifact_body_unsupported", message: "文件请求不符合接口契约。")
        }
        return try await fetchArtifactResponse(request, accept: accept)
    }
}

public struct V15ArtifactTransfer: Sendable, Equatable {
    public let data: Data
    public let headers: [String: String]
    public init(data: Data, headers: [String: String]) { self.data = data; self.headers = headers }
    public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

/// Internal wire conversion only. Public mutation services accept their
/// endpoint-specific `Encodable` contracts, never a caller-built JSON blob.
enum V15BodyEncoder {
    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        // Keep exact wire semantics aligned with APITransport.
        value.dateEncodingStrategy = .iso8601
        // Stable encoding makes keyed recovery auditable: a retry carries the
        // same serialized idempotency payload rather than merely equivalent
        // dictionary members in an arbitrary order.
        value.outputFormatting = [.sortedKeys]
        return value
    }()

    static func data<Value: Encodable>(_ value: Value) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw V15Failure(kind: .decoding, code: "request_encode_failed", message: "请求不符合接口契约。") }
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data(value)) }
        catch let failure as V15Failure { throw failure }
        catch { throw V15Failure(kind: .decoding, code: "request_encode_failed", message: "请求不符合接口契约。") }
    }
}

actor V15APITransportAdapter: V15Transporting {
    private let transport: APITransport
    init(transport: APITransport) { self.transport = transport }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        do {
            if let body {
                return try await transport.request(request.path, method: request.method, query: request.query, headers: request.headers, cache: request.method == "GET" && request.readCachePolicy == .standard, body: body)
            }
            return try await transport.request(request.path, method: request.method, query: request.query, headers: request.headers, cache: request.method == "GET" && request.readCachePolicy == .standard, body: Optional<String>.none)
        } catch is CancellationError {
            throw V15Failure(kind: .cancelled, message: "请求已取消。")
        } catch let failure as FiscalAPIError {
            throw V15ErrorMapper.map(failure)
        } catch {
            throw V15Failure(kind: .transport, message: "无法完成请求。")
        }
    }
    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws {
        do {
            if let body { try await transport.requestNoContent(request.path, method: request.method, body: body) }
            else { try await transport.requestNoContent(request.path, method: request.method, query: request.query) }
        } catch is CancellationError { throw V15Failure(kind: .cancelled, message: "请求已取消。") }
        catch let failure as FiscalAPIError { throw V15ErrorMapper.map(failure) }
        catch { throw V15Failure(kind: .transport, message: "无法完成请求。") }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
        do { return try await transport.rawDataGET(request.path, query: request.query, accept: accept) }
        catch is CancellationError { throw V15Failure(kind: .cancelled, message: "下载已取消。") }
        catch let failure as FiscalAPIError { throw V15ErrorMapper.map(failure) }
        catch { throw V15Failure(kind: .transport, message: "无法下载文件。") }
    }
    func fetchArtifactResponse(_ request: V15Request, accept: String) async throws -> V15ArtifactTransfer {
        do {
            let response = try await transport.rawDataGETResponse(request.path, query: request.query, accept: accept)
            return .init(data: response.data, headers: response.headers)
        } catch is CancellationError { throw V15Failure(kind: .cancelled, message: "下载已取消。") }
        catch let failure as FiscalAPIError { throw V15ErrorMapper.map(failure) }
        catch { throw V15Failure(kind: .transport, message: "无法下载文件。") }
    }
    func fetchArtifactResponse(_ request: V15Request, accept: String, body: JSONValue?) async throws -> V15ArtifactTransfer {
        do {
            let response = try await transport.rawDataResponse(request.path, method: request.method, query: request.query, accept: accept, body: body)
            return .init(data: response.data, headers: response.headers)
        } catch is CancellationError { throw V15Failure(kind: .cancelled, message: "下载已取消。") }
        catch let failure as FiscalAPIError { throw V15ErrorMapper.map(failure) }
        catch { throw V15Failure(kind: .transport, message: "无法下载文件。") }
    }
}

public enum V15ErrorMapper {
    public static func map(_ error: FiscalAPIError) -> V15Failure {
        switch error {
        case .transport:
            return .init(kind: .responseUnknown, code: "response_unknown", message: "连接在服务器确认前中断；请使用同一请求凭证重试。")
        case .invalidResponse:
            return .init(kind: .decoding, code: "invalid_response", message: "服务器响应无法解析。")
        case .rateLimited:
            return .init(kind: .transport, code: "rate_limited", message: error.displayMessage)
        case .unauthorized(let detail):
            return .init(kind: .transport, code: detail?.code, message: detail?.message ?? error.displayMessage)
        case .domain(let status, let detail):
            let issues = fieldIssues(from: detail.details, fallbackMessage: detail.message)
            if status == 409 {
                return .init(kind: .conflict, code: detail.code, message: detail.message, fieldIssues: issues, conflict: conflict(from: detail.details, message: detail.message))
            }
            return .init(kind: .transport, code: detail.code, message: detail.message, fieldIssues: issues)
        }
    }

    private static func fieldIssues(from value: JSONValue?, fallbackMessage: String) -> [V15FieldIssue] {
        if case .array(let values)? = value {
            return values.compactMap { issue in
                guard case .object(let object) = issue else { return nil }
                let path: String?
                if case .array(let locations)? = object["loc"] {
                    let components = locations.compactMap { location -> String? in
                        switch location { case .string(let value): return value == "body" ? nil : value; case .integer(let value): return "[\(value)]"; default: return nil }
                    }
                    path = components.reduce(into: "") { result, component in result += component.hasPrefix("[") ? component : (result.isEmpty ? component : ".\(component)") }
                } else { path = nil }
                let message = string(object["msg"]) ?? fallbackMessage
                return .init(code: "validation_error", message: message, fieldPath: path)
            }
        }
        guard case .object(let object)? = value else { return [] }
        if case .array(let values)? = object["field_issues"] {
            return values.compactMap { issue in
                guard case .object(let o) = issue, case .string(let code)? = o["code"], case .string(let message)? = o["message"] else { return nil }
                let path: String?; if case .string(let value)? = o["field_path"] { path = value } else { path = nil }
                return .init(code: code, message: message, fieldPath: path)
            }
        }
        let code = string(object["reason"]) ?? string(object["code"])
        guard let code else { return [] }
        return [.init(code: code, message: string(object["message"]) ?? fallbackMessage, fieldPath: string(object["field_path"]))]
    }

    private static func conflict(from value: JSONValue?, message: String) -> V15Conflict {
        guard case .object(let object)? = value else { return .init(reloadPath: nil, latestRevision: nil, message: message) }
        let resource: [String: JSONValue]
        if case .object(let nested)? = object["resource"] { resource = nested } else { resource = [:] }
        let reloadPath = string(object["reload_path"]) ?? string(resource["reload_path"])
        let locator = string(object["locator"]) ?? string(resource["locator"]) ?? string(resource["resource_id"])
        let expectedDataRevision = int64(object["expected_data_revision"])
        let currentDataRevision = int64(object["current_data_revision"])
        let revision = int64(object["data_revision"]) ?? currentDataRevision
        return .init(reloadPath: reloadPath, latestRevision: revision, expectedDataRevision: expectedDataRevision, currentDataRevision: currentDataRevision, currentVersion: int(object["current_version"]), expectedVersion: int(object["expected_version"]), safeToReload: bool(object["safe_to_reload"]), locator: locator, message: message)
    }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let result)? = value { result } else { nil } }
    private static func int64(_ value: JSONValue?) -> Int64? { switch value { case .integer(let result)?: result; case .decimal(let result)?: NSDecimalNumber(decimal: result).int64Value; default: nil } }
    private static func int(_ value: JSONValue?) -> Int? { int64(value).flatMap(Int.init(exactly:)) }
    private static func bool(_ value: JSONValue?) -> Bool? { if case .bool(let result)? = value { result } else { nil } }
}

public struct V15ReportArtifact: Sendable, Equatable {
    public let data: Data
    public let format: V15ReportArtifactFormat
    public let dataRevision: Int64
    public let filename: String
    public init(data: Data, format: V15ReportArtifactFormat, dataRevision: Int64, filename: String) { self.data = data; self.format = format; self.dataRevision = dataRevision; self.filename = filename }
}

/// A deliberately opaque encrypted Archive transfer.  The app never opens or
/// decodes these bytes: validation is limited to the server's transport
/// contract before a user-selected local handoff.
public struct V15ArchiveArtifact: Sendable, Equatable {
    public let data: Data
    public let filename: String
    public init(data: Data, filename: String) { self.data = data; self.filename = filename }
}

@MainActor public final class V15Services {
    public let session: V15SessionService
    public let system: V15SystemService
    public let masterData: V15MasterDataReadService
    public let ledger: V15LedgerCreateService
    public let creditCycles: V15CreditCycleReadService
    public let reports: V15ReportsService
    public let archives: V15ArchiveService
    public let attention: V15AttentionReadService
    public let merchants: V15MerchantService
    public let categories: V15CategoryTransformService
    public let credit: V15CreditService
    public let reimbursements: V15ReimbursementService
    public let installments: V15InstallmentService
    public let cashFlow: V15CashFlowService
    public let ai: V15AIService
    public let reconciliation: V15ReconciliationService
    public let statementImports: V15StatementImportService
    public let deepLinks: V15DeepLinkReadService
    public let pendingWrites: V15PendingWriteStore
    private let revisionStore: DataRevisionStore?
    private let offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)?

    /// Production injects `V15APITransportAdapter(APITransport(...))`. Fixture
    /// and offline implementations use exactly the same feature-facing surface.
    init(transport: any V15Transporting, revisionStore: DataRevisionStore? = nil, offlineSnapshotProvider: (@MainActor @Sendable () -> Date?)? = nil, saveAccessKey: (@Sendable (String) async throws -> Void)? = nil, pendingWrites: V15PendingWriteStore = .init()) {
        self.revisionStore = revisionStore
        self.offlineSnapshotProvider = offlineSnapshotProvider
        self.pendingWrites = pendingWrites
        session = .init(transport: transport, saveAccessKey: saveAccessKey)
        system = .init(transport: transport)
        masterData = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        ledger = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        creditCycles = .init(transport: transport)
        reports = .init(transport: transport)
        archives = .init(transport: transport)
        attention = .init(transport: transport)
        merchants = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        categories = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        credit = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        reimbursements = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        installments = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        cashFlow = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        ai = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        reconciliation = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        statementImports = .init(transport: transport, writable: { [weak revisionStore] in
            guard revisionStore?.offlineSnapshotAt == nil else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看，无法提交更改。") }
        })
        deepLinks = .init(transport: transport)
    }

    /// The production composition root. The only reused implementation details
    /// are transport/security/revision/offline primitives; no legacy repository
    /// or domain presentation type crosses this boundary.
    public convenience init(
        baseURL: URL,
        session: URLSession = .shared,
        accessKeyStore: AccessKeyStore = .init(),
        responseCache: HTTPResponseCache = .shared,
        offlineSnapshots: OfflineSnapshotStore = .shared,
        revisionStore: DataRevisionStore? = nil
    ) {
        let api = APITransport(
            baseURL: baseURL, session: session, accessKeyStore: accessKeyStore,
            responseCache: responseCache, offlineSnapshots: offlineSnapshots,
            revisionStore: revisionStore)
        self.init(
            transport: V15APITransportAdapter(transport: api),
            revisionStore: revisionStore,
            saveAccessKey: { key in try await accessKeyStore.save(key) },
            pendingWrites: V15PendingWriteStore(defaults: .standard)
        )
    }

    public var offlineSnapshotAt: Date? { offlineSnapshotProvider?() ?? revisionStore?.offlineSnapshotAt }
}

public struct V15SessionService: Sendable {
    private let transport: any V15Transporting
    private let saveAccessKey: (@Sendable (String) async throws -> Void)?
    init(transport: any V15Transporting, saveAccessKey: (@Sendable (String) async throws -> Void)?) { self.transport = transport; self.saveAccessKey = saveAccessKey }
    public func unlock(passphrase: String) async throws -> V15SessionResponse {
        let response: V15SessionResponse = try await transport.send(.init(path: "auth/session", method: "POST"), body: try V15BodyEncoder.encode(V15SessionRequest(passphrase: passphrase)))
        do { try await saveAccessKey?(response.accessKey) }
        catch { throw V15Failure(kind: .transport, code: "access_key_store_failed", message: "口令已验证，但本机连接凭证未能保存。") }
        return response
    }

    /// A QA-only process environment may provide a disposable local access
    /// key before the first status read.  Production never bundles that value:
    /// it is still persisted by the same access-key boundary as a normal
    /// passphrase session.
    public func saveBootstrapAccessKeyIfPresent(_ key: String?) async throws {
        guard let key, !key.isEmpty else { return }
        do { try await saveAccessKey?(key) }
        catch { throw V15Failure(kind: .transport, code: "access_key_store_failed", message: "本机连接凭证未能保存。") }
    }
    public func status() async throws -> V15AuthStatus { try await transport.send(.init(path: "auth/status"), body: nil) }
}

public struct V15SystemService: Sendable {
    private let transport: any V15Transporting
    init(transport: any V15Transporting) { self.transport = transport }
    public func status() async throws -> V15SystemStatus { try await transport.send(.init(path: "system/status"), body: nil) }
}

public struct V15MasterDataReadService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func activeAccounts() async throws -> [V15AccountResponse] { try await transport.send(.init(path: "accounts", query: [.init(name: "include_archived", value: "false")]), body: nil) }
    public func activeCategories(direction: V15CategoryDirection? = nil) async throws -> [V15CategoryResponse] {
        var query = [URLQueryItem(name: "include_archived", value: "false")]
        if let direction, direction != .unknown { query.append(.init(name: "direction", value: direction.rawValue)) }
        return try await transport.send(.init(path: "categories", query: query), body: nil)
    }
    public func accounts(includeArchived: Bool = true) async throws -> [V15AccountResponse] { try await transport.send(.init(path: "accounts", query: [.init(name: "include_archived", value: String(includeArchived))]), body: nil) }
    public func account(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15AccountResponse { try await transport.send(.init(path: "accounts/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func createAccount(_ draft: V15AccountDraft) async throws -> V15AccountResponse { try await writable(); return try await transport.send(.init(path: "accounts", method: "POST"), body: try V15BodyEncoder.encode(draft)) }
    public func patchAccount(id: UUID, patch: V15AccountPatch) async throws -> V15AccountResponse { try await writable(); return try await transport.send(.init(path: "accounts/\(id)", method: "PATCH"), body: try V15BodyEncoder.encode(patch)) }
    public func archiveAccount(id: UUID, expectedVersion: Int) async throws -> V15AccountResponse { try await versioned(path: "accounts/\(id)/archive", expectedVersion: expectedVersion) }
    public func restoreAccount(id: UUID, expectedVersion: Int) async throws -> V15AccountResponse { try await versioned(path: "accounts/\(id)/restore", expectedVersion: expectedVersion) }
    public func accountOrderState() async throws -> V15AccountOrderState { try await transport.send(.init(path: "accounts/order-state"), body: nil) }
    public func reorderAccounts(_ request: V15OrderRequest) async throws -> [V15AccountResponse] { try await writable(); return try await transport.send(.init(path: "accounts/order", method: "PUT"), body: try V15BodyEncoder.encode(request)) }
    public func categories(direction: V15CategoryDirection? = nil, includeArchived: Bool = true) async throws -> [V15CategoryResponse] { var q = [URLQueryItem(name: "include_archived", value: String(includeArchived))]; if let direction, direction != .unknown { q.append(.init(name: "direction", value: direction.rawValue)) }; return try await transport.send(.init(path: "categories", query: q), body: nil) }
    public func category(id: UUID) async throws -> V15CategoryResponse { try await transport.send(.init(path: "categories/\(id)"), body: nil) }
    public func createCategory(_ draft: V15CategoryDraft) async throws -> V15CategoryResponse { try await writable(); return try await transport.send(.init(path: "categories", method: "POST"), body: try V15BodyEncoder.encode(draft)) }
    public func patchCategory(id: UUID, patch: V15CategoryPatch) async throws -> V15CategoryResponse { try await writable(); return try await transport.send(.init(path: "categories/\(id)", method: "PATCH"), body: try V15BodyEncoder.encode(patch)) }
    public func archiveCategory(id: UUID, expectedVersion: Int) async throws -> V15CategoryResponse { try await categoryVersioned(path: "categories/\(id)/archive", expectedVersion: expectedVersion) }
    public func restoreCategory(id: UUID, expectedVersion: Int) async throws -> V15CategoryResponse { try await categoryVersioned(path: "categories/\(id)/restore", expectedVersion: expectedVersion) }
    public func categoryOrderState(direction: V15CategoryDirection, parentID: UUID? = nil) async throws -> V15CategoryOrderState { var q = [URLQueryItem(name: "direction", value: direction.rawValue)]; if let parentID { q.append(.init(name: "parent_id", value: parentID.uuidString)) }; return try await transport.send(.init(path: "categories/order-state", query: q), body: nil) }
    public func reorderCategories(parentID: UUID?, request: V15OrderRequest) async throws -> [V15CategoryResponse] { try await writable(); struct Body: Codable { let parentID: UUID?; let orderedIDs: [UUID]; let expectedListRevision: String; enum CodingKeys: String, CodingKey { case parentID = "parent_id", orderedIDs = "ordered_ids", expectedListRevision = "expected_list_revision" } }; let body = Body(parentID: parentID, orderedIDs: request.orderedIDs, expectedListRevision: request.expectedListRevision); return try await transport.send(.init(path: "categories/order", method: "PUT"), body: try V15BodyEncoder.encode(body)) }
    private func versioned(path: String, expectedVersion: Int) async throws -> V15AccountResponse { try await writable(); struct Version: Codable { let expectedVersion: Int; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" } }; return try await transport.send(.init(path: path, method: "POST"), body: try V15BodyEncoder.encode(Version(expectedVersion: expectedVersion))) }
    private func categoryVersioned(path: String, expectedVersion: Int) async throws -> V15CategoryResponse { try await writable(); struct Version: Codable { let expectedVersion: Int; enum CodingKeys: String, CodingKey { case expectedVersion = "expected_version" } }; return try await transport.send(.init(path: path, method: "POST"), body: try V15BodyEncoder.encode(Version(expectedVersion: expectedVersion))) }
}

public struct V15LedgerCreateService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    /// A write may have reached the server even when no response can be used.
    /// Callers must read back facts and revisions before offering another write.
    /// Request encoding failures are deterministic and intentionally excluded.
    public static func outcomeMayBeUnknown(_ failure: V15Failure) -> Bool {
        failure.kind == .responseUnknown || failure.kind == .cancelled ||
            (failure.kind == .decoding && failure.code == "invalid_response") ||
            (failure.kind == .transport && failure.code == nil)
    }
    public func create(_ request: V15TransactionCreateRequest, idempotencyKey: UUID) async throws -> V15Transaction {
        try await writable()
        return try await transport.send(.init(path: "transactions", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request))
    }
    public func list(_ filter: V15LedgerFilter) async throws -> V15Page<V15Transaction> {
        guard (1...100).contains(filter.limit) else { throw V15Failure(kind: .decoding, code: "invalid_limit", message: "账目列表每页数量须在 1 到 100 之间。") }
        guard filter.amountMinMinor.map({ $0 > 0 }) ?? true, filter.amountMaxMinor.map({ $0 > 0 }) ?? true else { throw V15Failure(kind: .decoding, code: "invalid_amount_filter", message: "金额筛选须大于 0。") }
        var query = [URLQueryItem(name: "limit", value: String(filter.limit)), URLQueryItem(name: "include_voided", value: String(filter.includeVoided)), URLQueryItem(name: "classification", value: filter.classification)]
        if let value = filter.cursor { query.append(.init(name: "cursor", value: value)) }
        if let value = filter.kind { query.append(.init(name: "kind", value: value)) }
        if let value = filter.accountID { query.append(.init(name: "account_id", value: value.uuidString)) }
        if let value = filter.categoryID { query.append(.init(name: "category_id", value: value.uuidString)) }
        if let value = filter.dateFrom { query.append(.init(name: "date_from", value: value)) }
        if let value = filter.dateTo { query.append(.init(name: "date_to", value: value)) }
        if let value = filter.query, !value.isEmpty { query.append(.init(name: "query", value: value)) }
        if let value = filter.source { query.append(.init(name: "source", value: value)) }
        if let value = filter.amountMinMinor { query.append(.init(name: "amount_min_minor", value: String(value))) }
        if let value = filter.amountMaxMinor { query.append(.init(name: "amount_max_minor", value: String(value))) }
        return try await transport.send(.init(path: "transactions", query: query), body: nil)
    }
    public func get(transactionID: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15Transaction { try await transport.send(.init(path: "transactions/\(transactionID)", readCachePolicy: readCachePolicy), body: nil) }
    public func replace(transactionID: UUID, request: V15TransactionReplaceRequest) async throws -> V15Transaction {
        try await writable(); return try await transport.send(.init(path: "transactions/\(transactionID)", method: "PUT"), body: try V15BodyEncoder.encode(request))
    }
    public func void(transactionID: UUID, expectedVersion: Int) async throws -> V15Transaction {
        try await writable(); return try await transport.send(.init(path: "transactions/\(transactionID)/void", method: "POST"), body: try V15BodyEncoder.encode(V15TransactionVersionRequest(expectedVersion: expectedVersion)))
    }
    public func restore(transactionID: UUID, expectedVersion: Int) async throws -> V15Transaction {
        try await writable(); return try await transport.send(.init(path: "transactions/\(transactionID)/restore", method: "POST"), body: try V15BodyEncoder.encode(V15TransactionVersionRequest(expectedVersion: expectedVersion)))
    }
    public func revisions(transactionID: UUID, cursor: String? = nil, limit: Int = 30) async throws -> V15TransactionRevisionPage {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_limit", message: "历史每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "transactions/\(transactionID)/revisions", query: query), body: nil)
    }
    public func provenance(transactionID: UUID) async throws -> V15TransactionProvenance { try await transport.send(.init(path: "transactions/\(transactionID)/provenance"), body: nil) }
}

/// This F1-A read is intentionally narrow: it provides an authoritative,
/// human-selectable repayment cycle and does not expose schedule mutation.
public struct V15CreditCycleReadService: Sendable {
    private let transport: any V15Transporting
    init(transport: any V15Transporting) { self.transport = transport }
    public func list(accountID: UUID, cursor: String? = nil, limit: Int = 100) async throws -> V15CreditCyclePage {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_credit_cycle_limit", message: "账期每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "credit-accounts/\(accountID)/cycles", query: query), body: nil)
    }
}

public struct V15ReportsService: Sendable {
    private let transport: any V15Transporting
    init(transport: any V15Transporting) { self.transport = transport }
    public func facts(windowDays: Int = 30, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15Facts {
        guard (1...90).contains(windowDays) else { throw V15Failure(kind: .decoding, code: "invalid_facts_window", message: "当前事实窗口须在 1 到 90 天之间。") }
        return try await transport.send(.init(path: "reports/facts", query: [.init(name: "window_days", value: String(windowDays))], readCachePolicy: readCachePolicy), body: nil)
    }
    public func drillDown(scope: V15DrillDownScope, cursor: String? = nil, limit: Int = 50) async throws -> V15FactDrillDown {
        guard ["cash_accounts", "credit_cycles", "reimbursement_outstanding", "completeness_issues"].contains(scope.scopeType) else { throw V15Failure(kind: .decoding, code: "unsupported_facts_scope", message: "当前版本无法读取该事实范围。") }
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_facts_limit", message: "事实下钻每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "scope", value: scope.scopeType), .init(name: "expected_data_revision", value: String(scope.expectedDataRevision)), .init(name: "limit", value: String(limit))]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "reports/facts/drill-down", query: query), body: nil)
    }
    public func futureEvents(windowDays: Int, accountID: UUID? = nil, cursor: String? = nil, limit: Int = 50, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15FutureEvents {
        guard [7, 30, 60, 90].contains(windowDays) else { throw V15Failure(kind: .decoding, code: "invalid_future_events_window", message: "未来时间线窗口只能是 7、30、60 或 90 天。") }
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_future_events_limit", message: "未来时间线每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "window_days", value: String(windowDays)), .init(name: "limit", value: String(limit))]
        if let accountID { query.append(.init(name: "account_id", value: accountID.uuidString)) }; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "reports/future-events", query: query, readCachePolicy: readCachePolicy), body: nil)
    }
    public func monthly(_ period: V15ReportMonth, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15PeriodReport { try await transport.send(.init(path: "reports/monthly/\(period.rawValue)", readCachePolicy: readCachePolicy), body: nil) }
    public func yearly(_ period: V15ReportYear, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15PeriodReport { try await transport.send(.init(path: "reports/yearly/\(period.rawValue)", readCachePolicy: readCachePolicy), body: nil) }
    public func periodDrillDown(period: V15ReportPeriod, expectedRevision: Int64, filter: V15ReportDrillFilter, cursor: String? = nil, limit: Int = 50, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15PeriodReportDrillDown {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_period_report_limit", message: "报告明细每页数量须在 1 到 100 之间。") }
        guard let filterItem = filter.queryItem else { throw V15Failure(kind: .decoding, code: "unsafe_period_report_filter", message: "此汇总没有可安全定位的明细筛选条件。") }
        var query = [URLQueryItem(name: "period_kind", value: period.kind.rawValue), .init(name: "period", value: period.rawValue), .init(name: "expected_data_revision", value: String(expectedRevision)), .init(name: "limit", value: String(limit))]
        query.append(filterItem)
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "reports/period-drill-down", query: query, readCachePolicy: readCachePolicy), body: nil)
    }
    public func monthlyArtifact(_ period: V15ReportMonth, format: V15ReportArtifactFormat, expectedDataRevision: Int64) async throws -> V15ReportArtifact {
        try await artifact(.init(path: "reports/monthly/\(period.rawValue)/export.\(format.rawValue)", query: [.init(name: "expected_data_revision", value: String(expectedDataRevision))]), format: format, expectedDataRevision: expectedDataRevision)
    }
    public func yearlyArtifact(_ period: V15ReportYear, format: V15ReportArtifactFormat, expectedDataRevision: Int64) async throws -> V15ReportArtifact {
        try await artifact(.init(path: "reports/yearly/\(period.rawValue)/export.\(format.rawValue)", query: [.init(name: "expected_data_revision", value: String(expectedDataRevision))]), format: format, expectedDataRevision: expectedDataRevision)
    }
    private func artifact(_ request: V15Request, format: V15ReportArtifactFormat, expectedDataRevision: Int64) async throws -> V15ReportArtifact {
        let response = try await transport.fetchArtifactResponse(request, accept: format.accept)
        guard response.header("Content-Type")?.lowercased().split(separator: ";").first.map(String.init) == format.accept,
              let rawRevision = response.header("X-Fiscal-Data-Revision"), let revision = Int64(rawRevision), revision >= 0, revision == expectedDataRevision,
              let disposition = response.header("Content-Disposition"), let filename = Self.safeAttachmentFilename(disposition, format: format), !response.data.isEmpty, response.data.count <= 5 * 1024 * 1024 else {
            throw V15Failure(kind: .decoding, code: "invalid_report_artifact", message: "导出文件无法与当前报告版本安全绑定。")
        }
        return .init(data: response.data, format: format, dataRevision: revision, filename: filename)
    }
    private static func safeAttachmentFilename(_ disposition: String, format: V15ReportArtifactFormat) -> String? {
        guard let match = disposition.range(of: "filename=\\\"?([^\\\";]+)", options: .regularExpression) else { return nil }
        let candidate = String(disposition[match]).replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\\\" "))
        guard candidate.utf8.count <= 180, candidate.rangeOfCharacter(from: .controlCharacters) == nil,
              !candidate.contains("/"), !candidate.contains("\\\\"), candidate.lowercased().hasSuffix(".\(format.rawValue)") else { return nil }
        return candidate
    }
}

/// The Archive protocol is intentionally separate from report export: it is
/// POST-only, password-bearing, has no revision claim, and always excludes
/// raw AI input.  No restore endpoint exists at this boundary.
public struct V15ArchiveService: Sendable {
    private let transport: any V15Transporting
    init(transport: any V15Transporting) { self.transport = transport }

    public func export(password: String) async throws -> V15ArchiveArtifact {
        guard (12...128).contains(password.count) else {
            throw V15Failure(kind: .decoding, code: "invalid_archive_password", message: "归档密码须为 12 到 128 个字符。")
        }
        let body = try V15BodyEncoder.encode(V15ArchiveExportRequest(password: password, includeAIRaw: false))
        let response = try await transport.fetchArtifactResponse(
            .init(path: "archives/export", method: "POST"),
            accept: "application/vnd.fiscal.archive+json",
            body: body
        )
        guard response.header("Content-Type")?.lowercased().split(separator: ";").first.map(String.init) == "application/vnd.fiscal.archive+json",
              response.header("Cache-Control")?.lowercased().contains("no-store") == true,
              response.header("X-Content-Type-Options")?.lowercased() == "nosniff",
              let disposition = response.header("Content-Disposition"),
              let filename = Self.safeFilename(disposition),
              !response.data.isEmpty, response.data.count <= 5 * 1024 * 1024 else {
            throw V15Failure(kind: .decoding, code: "invalid_archive_artifact", message: "加密归档文件无法安全验证。")
        }
        return .init(data: response.data, filename: filename)
    }

    private static func safeFilename(_ disposition: String) -> String? {
        guard let match = disposition.range(of: "filename=\\\"?([^\\\";]+)", options: .regularExpression) else { return nil }
        let candidate = String(disposition[match]).replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\\\" "))
        guard candidate == "fiscal-archive-v1.far", candidate.utf8.count <= 180,
              candidate.rangeOfCharacter(from: .controlCharacters) == nil,
              !candidate.contains("/"), !candidate.contains("\\\\") else { return nil }
        return candidate
    }
}

public struct V15AttentionReadService: Sendable {
    private let transport: any V15Transporting
    init(transport: any V15Transporting) { self.transport = transport }
    public func list() async throws -> V15AttentionPage { try await transport.send(.init(path: "reconciliation/attention"), body: nil) }
}

public struct V15MerchantService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func list(query search: String? = nil, cursor: String? = nil, limit: Int = 50, includeArchived: Bool = false) async throws -> V15Page<V15Merchant> { var query = [URLQueryItem(name: "limit", value: String(limit)), .init(name: "include_archived", value: String(includeArchived))]; if let search, !search.isEmpty { query.append(.init(name: "query", value: search)) }; if let cursor { query.append(.init(name: "cursor", value: cursor)) }; return try await transport.send(.init(path: "merchants", query: query), body: nil) }
    public func get(id: UUID) async throws -> V15Merchant { try await transport.send(.init(path: "merchants/\(id)"), body: nil) }
    public func create(_ draft: V15MerchantDraft) async throws -> V15Merchant { try await writable(); return try await transport.send(.init(path: "merchants", method: "POST"), body: try V15BodyEncoder.encode(draft)) }
    public func patch(id: UUID, patch: V15MerchantPatch) async throws -> V15Merchant { try await writable(); return try await transport.send(.init(path: "merchants/\(id)", method: "PATCH"), body: try V15BodyEncoder.encode(patch)) }
    public func history(transactionID: UUID, cursor: String? = nil) async throws -> V15Page<V15JSONRecord> { var query: [URLQueryItem] = []; if let cursor { query.append(.init(name: "cursor", value: cursor)) }; return try await transport.send(.init(path: "transactions/\(transactionID)/revisions", query: query), body: nil) }
    public func mapping(transactionID: UUID) async throws -> V15MerchantMapping? { try await transport.send(.init(path: "transactions/\(transactionID)/merchant-mapping"), body: nil) }
    public func confirmMapping(transactionID: UUID, request: V15MerchantMappingRequest, idempotencyKey: UUID) async throws -> V15MerchantMappingReceipt { try await writable(); return try await transport.send(.init(path: "transactions/\(transactionID)/merchant-mapping", method: "PUT", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func releaseMapping(transactionID: UUID, request: V15MerchantMappingReleaseRequest, idempotencyKey: UUID) async throws -> V15MerchantMappingReceipt { try await writable(); return try await transport.send(.init(path: "transactions/\(transactionID)/merchant-mapping", method: "DELETE", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
}

public struct V15JSONRecord: Codable, Sendable { public let values: JSONValue; public init(from decoder: Decoder) throws { values = try JSONValue(from: decoder) }; public func encode(to encoder: Encoder) throws { try values.encode(to: encoder) } }

public struct V15CategoryTransformService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func mergePreview(sourceID: UUID, request: V15CategoryMergePreviewRequest) async throws -> V15CategoryMergePreview { try await writable(); return try await transport.send(.init(path: "categories/\(sourceID)/merge-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func splitPreview(rootID: UUID, request: V15CategorySplitPreviewRequest) async throws -> V15CategorySplitPreview { try await writable(); return try await transport.send(.init(path: "categories/\(rootID)/split-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func commitMerge(sourceID: UUID, request: V15CategoryMergeCommitRequest, idempotencyKey: UUID) async throws -> V15CategoryTransformReceipt { try await writable(); return try await transport.send(.init(path: "categories/\(sourceID)/merge-commit", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func commitSplit(rootID: UUID, request: V15CategorySplitCommitRequest, idempotencyKey: UUID) async throws -> V15CategoryTransformReceipt { try await writable(); return try await transport.send(.init(path: "categories/\(rootID)/split-commit", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
}

public struct V15CreditService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func accounts() async throws -> [V15CreditAccountSummary] { try await transport.send(.init(path: "credit-accounts"), body: nil) }
    public func account(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15CreditAccountSummary { try await transport.send(.init(path: "credit-accounts/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func cycles(accountID: UUID, cursor: String? = nil, limit: Int = 50, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15CreditCyclePage {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_credit_cycle_limit", message: "账期每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "credit-accounts/\(accountID)/cycles", query: query, readCachePolicy: readCachePolicy), body: nil)
    }
    public func cycle(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15CreditCycle { try await transport.send(.init(path: "credit-cycles/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func transactions(cycleID: UUID, cursor: String? = nil, limit: Int = 50) async throws -> V15Page<V15Transaction> {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_credit_cycle_transaction_limit", message: "账期账目每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "credit-cycles/\(cycleID)/transactions", query: query), body: nil)
    }
    public func schedulePreview(accountID: UUID, request: V15CreditScheduleChangeRequest) async throws -> V15CreditSchedulePreview { try await writable(); return try await transport.send(.init(path: "credit-accounts/\(accountID)/schedule-change-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func commitSchedule(accountID: UUID, request: V15CreditScheduleChangeCommitRequest, idempotencyKey: UUID) async throws -> V15CreditSchedulePreview { try await writable(); return try await transport.send(.init(path: "credit-accounts/\(accountID)/schedule-change", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
}

public struct V15ReimbursementService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func claims(status: V15ReimbursementClaimStatus? = nil, query: String? = nil, expenseTransactionID: UUID? = nil, includeArchived: Bool = false, includeVoided: Bool = false, cursor: String? = nil, limit: Int = 20, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15Page<V15ReimbursementClaim> {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_reimbursement_claim_limit", message: "报销单每页数量须在 1 到 100 之间。") }
        var parameters = [URLQueryItem(name: "limit", value: String(limit)), .init(name: "include_archived", value: String(includeArchived)), .init(name: "include_voided", value: String(includeVoided))]
        if let status { guard status.isKnown else { throw V15Failure(kind: .decoding, code: "unknown_reimbursement_status_filter", message: "未知报销状态只可展示，不能用于筛选。") }; parameters.append(.init(name: "status", value: status.rawValue)) }
        if let query, !query.isEmpty { parameters.append(.init(name: "query", value: query)) }
        if let expenseTransactionID { parameters.append(.init(name: "expense_transaction_id", value: expenseTransactionID.uuidString)) }
        if let cursor { parameters.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "reimbursement-claims", query: parameters, readCachePolicy: readCachePolicy), body: nil)
    }
    public func claim(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15ReimbursementClaim { try await transport.send(.init(path: "reimbursement-claims/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func receipts(claimID: UUID, cursor: String? = nil, limit: Int = 20, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15Page<V15ReimbursementReceipt> { guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_reimbursement_receipt_limit", message: "到账记录每页数量须在 1 到 100 之间。") }; var query = [URLQueryItem(name: "limit", value: String(limit))]; if let cursor { query.append(.init(name: "cursor", value: cursor)) }; return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/receipts", query: query, readCachePolicy: readCachePolicy), body: nil) }
    public func receipt(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15ReimbursementReceipt { try await transport.send(.init(path: "reimbursement-receipts/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func candidates(query: String? = nil, dateFrom: String? = nil, dateTo: String? = nil, cursor: String? = nil, limit: Int = 30, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15Page<V15ReimbursementCandidate> { guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_reimbursement_candidate_limit", message: "垫付候选每页数量须在 1 到 100 之间。") }; var parameters = [URLQueryItem(name: "limit", value: String(limit))]; if let query, !query.isEmpty { parameters.append(.init(name: "query", value: query)) }; if let dateFrom { parameters.append(.init(name: "date_from", value: dateFrom)) }; if let dateTo { parameters.append(.init(name: "date_to", value: dateTo)) }; if let cursor { parameters.append(.init(name: "cursor", value: cursor)) }; return try await transport.send(.init(path: "reimbursement-expense-candidates", query: parameters, readCachePolicy: readCachePolicy), body: nil) }
    public func receiptAccountOptions(readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15ReceiptAccountOptions { try await transport.send(.init(path: "reimbursement-receipt-account-options", readCachePolicy: readCachePolicy), body: nil) }
    public func createClaim(_ request: V15ReimbursementClaimDraft, idempotencyKey: UUID) async throws -> V15ReimbursementClaim { try await writable(); return try await transport.send(.init(path: "reimbursement-claims", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func previewClaim(claimID: UUID, request: V15ReimbursementClaimPreviewRequest) async throws -> V15ReimbursementClaimPreview { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func previewCancellation(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementCancelPreview { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/cancel-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func previewReceipt(claimID: UUID, request: V15ReimbursementReceiptDraft) async throws -> V15ReimbursementReceiptPreview { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/receipt-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func previewReceiptReplacement(receiptID: UUID, request: V15ReimbursementReceiptReplacePreviewRequest) async throws -> V15ReimbursementReceiptPreview { try await writable(); return try await transport.send(.init(path: "reimbursement-receipts/\(receiptID)/preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func commitClaimReplacement(claimID: UUID, request: V15ReimbursementClaimCommitRequest, idempotencyKey: UUID) async throws -> V15ReimbursementClaim { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)", method: "PUT", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func commitCancellation(claimID: UUID, request: V15ReimbursementCancelCommitRequest, idempotencyKey: UUID) async throws -> V15ReimbursementClaim { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/cancel-outstanding", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func createReceipt(claimID: UUID, request: V15ReimbursementReceiptCreateCommitRequest, idempotencyKey: UUID) async throws -> V15ReimbursementReceipt { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/receipts", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func replaceReceipt(receiptID: UUID, request: V15ReimbursementReceiptReplaceCommitRequest, idempotencyKey: UUID) async throws -> V15ReimbursementReceipt { try await writable(); return try await transport.send(.init(path: "reimbursement-receipts/\(receiptID)", method: "PUT", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func submit(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "submit", request: request) }
    public func retractSubmission(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "retract-submission", request: request) }
    public func reopen(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "reopen", request: request) }
    public func voidClaim(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "void", request: request) }
    public func restoreClaim(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "restore", request: request) }
    public func archive(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "archive", request: request) }
    public func unarchive(claimID: UUID, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await directClaimAction(claimID: claimID, action: "unarchive", request: request) }
    public func voidReceipt(receiptID: UUID, request: V15ReimbursementReceiptVersionRequest) async throws -> V15ReimbursementReceipt { try await directReceiptAction(receiptID: receiptID, action: "void", request: request) }
    public func restoreReceipt(receiptID: UUID, request: V15ReimbursementReceiptVersionRequest) async throws -> V15ReimbursementReceipt { try await directReceiptAction(receiptID: receiptID, action: "restore", request: request) }
    private func directClaimAction(claimID: UUID, action: String, request: V15ReimbursementVersionRequest) async throws -> V15ReimbursementClaim { try await writable(); return try await transport.send(.init(path: "reimbursement-claims/\(claimID)/\(action)", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    private func directReceiptAction(receiptID: UUID, action: String, request: V15ReimbursementReceiptVersionRequest) async throws -> V15ReimbursementReceipt { try await writable(); return try await transport.send(.init(path: "reimbursement-receipts/\(receiptID)/\(action)", method: "POST"), body: try V15BodyEncoder.encode(request)) }
}

public struct V15InstallmentService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func list(accountID: UUID? = nil, status: String? = nil, cursor: String? = nil, limit: Int = 20, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15InstallmentPlanPage {
        guard (1...100).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_installment_limit", message: "分期计划每页数量须在 1 到 100 之间。") }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let accountID { query.append(.init(name: "account_id", value: accountID.uuidString)) }
        if let status { query.append(.init(name: "status", value: status)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await transport.send(.init(path: "installment-plans", query: query, readCachePolicy: readCachePolicy), body: nil)
    }
    public func plan(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15InstallmentPlan { try await transport.send(.init(path: "installment-plans/\(id)", readCachePolicy: readCachePolicy), body: nil) }
    public func eligibility(transactionID: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15InstallmentEligibility { try await transport.send(.init(path: "transactions/\(transactionID)/installment-eligibility", readCachePolicy: readCachePolicy), body: nil) }
    public func cycleOptions(purchaseTransactionID: UUID, months: Int = 60, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> [V15InstallmentCycleOption] {
        guard (1...60).contains(months) else { throw V15Failure(kind: .decoding, code: "invalid_installment_months", message: "分期月份须在 1 到 60 之间。") }
        let query = [URLQueryItem(name: "purchase_transaction_id", value: purchaseTransactionID.uuidString), URLQueryItem(name: "months", value: String(months))]
        return try await transport.send(.init(path: "installment-cycle-options", query: query, readCachePolicy: readCachePolicy), body: nil)
    }
    public func liabilities(accountID: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15InstallmentLiabilities { try await transport.send(.init(path: "installment-liabilities", query: [.init(name: "account_id", value: accountID.uuidString)], readCachePolicy: readCachePolicy), body: nil) }
    public func previewPurchase(_ request: V15InstallmentPurchaseCreateRequest) async throws -> V15InstallmentPurchasePreview { try await writable(); return try await transport.send(.init(path: "installment-purchases/preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func createPurchase(_ request: V15InstallmentPurchaseCreateRequest, idempotencyKey: UUID) async throws -> V15InstallmentPurchaseCreateResponse { try await writable(); return try await transport.send(.init(path: "installment-purchases", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func createPlan(_ request: V15InstallmentCreateRequest, idempotencyKey: UUID) async throws -> V15InstallmentPlan { try await writable(); return try await transport.send(.init(path: "installment-plans", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func previewPlan(planID: UUID, request: V15InstallmentReplacementRequest) async throws -> V15InstallmentPlanChangePreview { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    /// This endpoint intentionally has no preview token and no idempotency key.
    /// A response-unknown caller must use a fresh GET and compare intent; the
    /// service does not expose a retry variant that could duplicate the PUT.
    public func updatePlan(planID: UUID, request: V15InstallmentReplacementRequest) async throws -> V15InstallmentPlan { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)", method: "PUT"), body: try V15BodyEncoder.encode(request)) }
    public func settlementPreview(planID: UUID, request: V15InstallmentSettlementRequest) async throws -> V15InstallmentSettlementPreview { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/settlement-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func reverseSettlementPreview(planID: UUID, request: V15InstallmentActionRequest) async throws -> V15InstallmentReverseSettlementPreview { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/reverse-settlement-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func cancellationPreview(planID: UUID, request: V15InstallmentActionRequest) async throws -> V15InstallmentCancellationPreview { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/cancel-preview", method: "POST"), body: try V15BodyEncoder.encode(request)) }
    public func settleEarly(planID: UUID, request: V15InstallmentSettlementRequest, idempotencyKey: UUID) async throws -> V15InstallmentSettlementResult { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/settle-early", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func cancelFuture(planID: UUID, request: V15InstallmentActionRequest, idempotencyKey: UUID) async throws -> V15InstallmentCancellationResult { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/cancel-future", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func reverseSettlement(planID: UUID, request: V15InstallmentActionRequest, idempotencyKey: UUID) async throws -> V15InstallmentReverseSettlementResult { try await writable(); return try await transport.send(.init(path: "installment-plans/\(planID)/reverse-settlement", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
}

public struct V15StatementImportService: Sendable {
    private let transport: any V15Transporting; private let writable: @MainActor @Sendable () throws -> Void
    init(transport: any V15Transporting, writable: @escaping @MainActor @Sendable () throws -> Void) { self.transport = transport; self.writable = writable }
    public func register(_ request: V15StatementImportRegistration) async throws -> V15StatementImportRegistrationResponse {
        try await writable(); return try await transport.send(.init(path: "statement-imports", method: "POST"), body: try V15BodyEncoder.encode(request))
    }
    public func statement(id: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15StatementImport {
        try await transport.send(.init(path: "statement-imports/\(id)", readCachePolicy: readCachePolicy), body: nil)
    }
    public func startExtraction(importID: UUID, expectedVersion: Int) async throws -> V15StatementImportAttempt {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/attempts", method: "POST"), body: try V15BodyEncoder.encode(V15StatementImportVersionRequest(expectedVersion: expectedVersion)))
    }
    public func submitEvidence(importID: UUID, request: V15StatementEvidenceSubmission) async throws -> V15StatementEvidenceResponse {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/evidence", method: "POST"), body: try V15BodyEncoder.encode(request))
    }
    public func fail(importID: UUID, expectedVersion: Int, code: String) async throws -> V15StatementImport {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/fail", method: "POST"), body: try V15BodyEncoder.encode(V15StatementImportFailureRequest(expectedVersion: expectedVersion, errorCode: code)))
    }
    public func abandon(importID: UUID, expectedVersion: Int) async throws -> V15StatementImport {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/abandon", method: "POST"), body: try V15BodyEncoder.encode(V15StatementImportVersionRequest(expectedVersion: expectedVersion)))
    }
    public func providerAttempt(importID: UUID, request: V15StatementProviderAttemptCreate, idempotencyKey: UUID) async throws -> V15StatementProviderAttempt { try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/provider-attempts", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(request)) }
    public func validationRun(importID: UUID, request: V15StatementValidationRunCreate) async throws -> V15StatementReview {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/validation-runs", method: "POST"), body: try V15BodyEncoder.encode(request))
    }
    public func workbench(importID: UUID, cursor: Int = 0, limit: Int = 100, filters: V15StatementWorkbenchFilter? = nil, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15StatementWorkbench {
        guard cursor >= 0, (1...200).contains(limit) else { throw V15Failure(kind: .decoding, code: "invalid_statement_page", message: "账单复核分页参数无效。") }
        var query = [URLQueryItem(name: "cursor", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))]
        if let filters { query.append(.init(name: "filters", value: String(data: try V15BodyEncoder.data(filters), encoding: .utf8))) }
        return try await transport.send(.init(path: "statement-imports/\(importID)/review-workbench", query: query, readCachePolicy: readCachePolicy), body: nil)
    }
    public func workbenchPage(importID: UUID, pageNumber: Int, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15StatementWorkbenchPage {
        guard pageNumber > 0 else { throw V15Failure(kind: .decoding, code: "invalid_statement_page", message: "账单页码无效。") }
        return try await transport.send(.init(path: "statement-imports/\(importID)/review-workbench/pages/\(pageNumber)", readCachePolicy: readCachePolicy), body: nil)
    }
    public func putResolution(importID: UUID, rowID: UUID, request: V15StatementDraftResolutionPut) async throws -> V15StatementReview {
        if case .unknown = request.resolution { throw V15Failure(kind: .decoding, code: "unknown_statement_resolution", message: "未知方案不能写入。") }
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/rows/\(rowID)/draft-resolution", method: "PUT"), body: try V15BodyEncoder.encode(request))
    }
    public func finalCreateDraft(importID: UUID, rowID: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15StatementFinalCreateDraft {
        try await transport.send(.init(path: "statement-imports/\(importID)/rows/\(rowID)/final-create-draft", readCachePolicy: readCachePolicy), body: nil)
    }
    public func putFinalCreateDraft(importID: UUID, rowID: UUID, request: V15StatementFinalCreateDraftPut) async throws -> V15StatementFinalCreateDraft {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/rows/\(rowID)/final-create-draft", method: "PUT"), body: try V15BodyEncoder.encode(request))
    }
    public func confirmationPreview(importID: UUID, rowIDs: [UUID]) async throws -> V15StatementConfirmationPreview {
        guard !rowIDs.isEmpty, Set(rowIDs).count == rowIDs.count else { throw V15Failure(kind: .decoding, code: "invalid_statement_selection", message: "请选择且仅选择一次要确认的行。") }
        return try await transport.send(.init(path: "statement-imports/\(importID)/confirmation-preview", method: "POST"), body: try V15BodyEncoder.encode(V15StatementConfirmationPreviewRequest(rowIDs: rowIDs)))
    }
    /// The preview's request is the only confirmed payload accepted here. The
    /// caller cannot construct versions from visible rows.
    public func confirm(importID: UUID, serverRequest: V15StatementConfirmRequest, idempotencyKey: UUID) async throws -> V15StatementConfirmationReceipt {
        try await writable(); return try await transport.send(.init(path: "statement-imports/\(importID)/confirm", method: "POST", headers: ["Idempotency-Key": idempotencyKey.uuidString]), body: try V15BodyEncoder.encode(serverRequest))
    }
    public func confirmationReceipt(importID: UUID, idempotencyKey: UUID, readCachePolicy: V15ReadCachePolicy = .standard) async throws -> V15StatementConfirmationReceipt {
        try await transport.send(.init(path: "statement-imports/\(importID)/confirmation-receipt", headers: ["Idempotency-Key": idempotencyKey.uuidString], readCachePolicy: readCachePolicy), body: nil)
    }
}

/// Deep links resolved by P30-B are reads, never instructions to perform a
/// hidden mutation. Features may decode domain-specific fields later.
public struct V15DeepLinkReadService: Sendable {
    private let transport: any V15Transporting
    init(transport: any V15Transporting) { self.transport = transport }
    public func checkpoint(_ id: UUID) async throws -> V15JSONRecord { try await transport.send(.init(path: "reconciliation/checkpoints/\(id)"), body: nil) }
    public func migrationRun(_ id: UUID) async throws -> V15JSONRecord { try await transport.send(.init(path: "migrations/runs/\(id)"), body: nil) }
    public func transactionCapabilities(_ id: UUID) async throws -> V15VersionedCapabilityResource { try await transport.send(.init(path: "transactions/\(id)"), body: nil) }
}
