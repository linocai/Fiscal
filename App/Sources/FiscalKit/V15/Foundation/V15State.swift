import Foundation

public struct V15DisabledReason: Sendable, Equatable {
    public let code: String
    public let message: String
    public let fieldPath: String?
    public static let unknownCapability = V15DisabledReason(code: "unknown_capability", message: "当前版本不支持此操作。", fieldPath: nil)
    public init(code: String, message: String, fieldPath: String?) { self.code = code; self.message = message; self.fieldPath = fieldPath }
}

public enum V15Capability: Sendable, Equatable {
    case enabled(action: String)
    case disabled(action: String, reason: V15DisabledReason)
}

public struct V15FieldIssue: Sendable, Equatable {
    public let code: String; public let message: String; public let fieldPath: String?
    public init(code: String, message: String, fieldPath: String? = nil) { self.code = code; self.message = message; self.fieldPath = fieldPath }
}

public struct V15Conflict: Sendable, Equatable {
    public let reloadPath: String?
    public let latestRevision: Int64?
    public let expectedDataRevision: Int64?
    public let currentDataRevision: Int64?
    public let currentVersion: Int?
    public let expectedVersion: Int?
    public let safeToReload: Bool?
    /// Opaque server locator only; the V15 layer neither logs nor infers a
    /// resource identity from it.
    public let locator: String?
    public let message: String
    public init(reloadPath: String?, latestRevision: Int64?, expectedDataRevision: Int64? = nil, currentDataRevision: Int64? = nil, currentVersion: Int? = nil, expectedVersion: Int? = nil, safeToReload: Bool? = nil, locator: String? = nil, message: String) { self.reloadPath = reloadPath; self.latestRevision = latestRevision; self.expectedDataRevision = expectedDataRevision; self.currentDataRevision = currentDataRevision; self.currentVersion = currentVersion; self.expectedVersion = expectedVersion; self.safeToReload = safeToReload; self.locator = locator; self.message = message }
}

public struct V15Failure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case transport, decoding, offlineReadOnly, responseUnknown, conflict, cancelled }
    public let kind: Kind; public let code: String?; public let message: String; public let fieldIssues: [V15FieldIssue]; public let conflict: V15Conflict?
    public init(kind: Kind, code: String? = nil, message: String, fieldIssues: [V15FieldIssue] = [], conflict: V15Conflict? = nil) { self.kind = kind; self.code = code; self.message = message; self.fieldIssues = fieldIssues; self.conflict = conflict }
}

public enum V15AsyncPhase<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(V15Failure, previous: Value?)
}

/// Owns a single async result. A stale request (including a cancellation) may
/// never overwrite a later request's state.
@MainActor public final class V15LoadState<Value: Sendable> {
    public private(set) var phase: V15AsyncPhase<Value> = .idle
    private var generation: UInt64 = 0
    public init() {}
    @discardableResult public func begin() -> UInt64 {
        generation &+= 1
        let previous: Value?
        switch phase { case .loaded(let value): previous = value; case .loading(let value): previous = value; case .failed(_, let value): previous = value; case .idle: previous = nil }
        phase = .loading(previous: previous); return generation
    }
    public func succeed(_ value: Value, generation candidate: UInt64) { guard candidate == generation else { return }; phase = .loaded(value) }
    public func fail(_ failure: V15Failure, generation candidate: UInt64) { guard candidate == generation else { return }; let previous: Value?; switch phase { case .loading(let value): previous = value; case .loaded(let value): previous = value; case .failed(_, let value): previous = value; case .idle: previous = nil }; phase = .failed(failure, previous: previous) }
    public func cancelled(generation candidate: UInt64) { guard candidate == generation else { return }; phase = .idle }
    public func invalidate() { generation &+= 1; phase = .idle }
}

public struct V15PreviewSession: Sendable, Equatable {
    public let token: UUID; public let inputDigest: String; public let expiresAt: Date?
    public init(token: UUID, inputDigest: String, expiresAt: Date? = nil) { self.token = token; self.inputDigest = inputDigest; self.expiresAt = expiresAt }
    public func isUsable(for digest: String, now: Date = .now) -> Bool { digest == inputDigest && (expiresAt.map { $0 > now } ?? true) }
}

@MainActor public final class V15PreviewLifecycle {
    public private(set) var session: V15PreviewSession?
    public init() {}
    public func accept(_ session: V15PreviewSession, generation: UInt64, currentGeneration: UInt64) { guard generation == currentGeneration else { return }; self.session = session }
    public func inputChanged() { session = nil }
    public func dismissed() { session = nil }
    public func cancelled() { session = nil }
    public func commitToken(for digest: String, now: Date = .now) -> UUID? { guard let session, session.isUsable(for: digest, now: now) else { self.session = nil; return nil }; return session.token }
}

/// A response-lost mutation keeps exactly the same idempotency key on retry.
@MainActor public final class V15IdempotencyOwner {
    private var keys: [String: UUID] = [:]
    public init() {}
    public func key(for scope: String) -> UUID { if let key = keys[scope] { return key }; let key = UUID(); keys[scope] = key; return key }
    /// A mutation retry belongs to the exact payload that was sent. Callers
    /// replace the payload identity as soon as an input changes; a stale key
    /// can therefore never be reused for a different request body.
    public func key(for scope: String, payloadIdentity: String) -> UUID { key(for: scopedIdentity(scope, payloadIdentity)) }
    public func succeeded(scope: String) { removeAll(in: scope) }
    public func succeeded(scope: String, payloadIdentity: String) { succeeded(scope: scopedIdentity(scope, payloadIdentity)) }
    public func abandon(scope: String) { removeAll(in: scope) }
    public func abandon(scope: String, payloadIdentity: String) { abandon(scope: scopedIdentity(scope, payloadIdentity)) }
    private func scopedIdentity(_ scope: String, _ payloadIdentity: String) -> String { "\(scope)\u{0}\(payloadIdentity)" }
    private func removeAll(in scope: String) { keys.keys.filter { $0 == scope || $0.hasPrefix(scope + "\u{0}") }.forEach { keys.removeValue(forKey: $0) } }
}
