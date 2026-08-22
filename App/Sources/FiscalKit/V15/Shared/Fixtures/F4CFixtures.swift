import Foundation

/// Synthetic route-only Archive transfers. No fixture includes real Archive
/// bytes, credentials, account identifiers, or provider values.
public enum V15F4CFixtures {
    @MainActor public static func services(route: String = "archive") -> V15Services { .init(transport: F4CTransport(mode: .route(route))) }
    @MainActor static func saver(route: String) -> F4CArchiveSaver { .init(mode: route == "archive-save-cancel" ? .cancelled : .saved) }
}

actor F4CTransport: V15Transporting {
    enum Mode: Equatable { case normal, loading, failure, unknown, failureThenSuccess, unknownThenSuccess, badType, badFilename, missingSecurity, oversized, offline
        static func route(_ route: String) -> Mode { switch route { case "archive-loading": .loading; case "archive-error": .failure; case "archive-unknown": .unknown; case "archive-error-retry": .failureThenSuccess; case "archive-unknown-retry": .unknownThenSuccess; case "archive-bad-type": .badType; case "archive-bad-filename": .badFilename; case "archive-missing-security": .missingSecurity; case "archive-too-large": .oversized; case "archive-offline": .offline; default: .normal } }
    }
    let mode: Mode
    private var requests: [V15Request] = []
    private var bodies: [JSONValue?] = []
    private var archiveAttempts = 0
    init(mode: Mode) { self.mode = mode }
    func recordedRequests() -> [V15Request] { requests }
    func recordedBodies() -> [JSONValue?] { bodies }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response { requests.append(request); bodies.append(body); throw V15Failure(kind: .decoding, message: "F4-C fixture has no JSON response") }
    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws { requests.append(request); bodies.append(body) }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .decoding, message: "Archive requires POST") }
    func fetchArtifactResponse(_ request: V15Request, accept: String) async throws -> V15ArtifactTransfer { throw V15Failure(kind: .decoding, message: "Archive requires POST") }
    func fetchArtifactResponse(_ request: V15Request, accept: String, body: JSONValue?) async throws -> V15ArtifactTransfer {
        requests.append(request); bodies.append(body)
        archiveAttempts += 1
        if mode == .offline { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线快照仅可查看。") }
        if mode == .loading { try await Task.sleep(for: .seconds(4)) }
        if mode == .failure || (mode == .failureThenSuccess && archiveAttempts == 1) { throw V15Failure(kind: .transport, message: "归档创建失败。") }
        if mode == .unknown || (mode == .unknownThenSuccess && archiveAttempts == 1) { throw V15Failure(kind: .responseUnknown, code: "response_unknown", message: "文件结果未知。") }
        var headers = ["Content-Type": "application/vnd.fiscal.archive+json", "Content-Disposition": "attachment; filename=\"fiscal-archive-v1.far\"", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]
        if mode == .badType { headers["Content-Type"] = "application/json" }
        if mode == .badFilename { headers["Content-Disposition"] = "attachment; filename=\"unsafe.far\"" }
        if mode == .missingSecurity { headers.removeValue(forKey: "Cache-Control") }
        let data = mode == .oversized ? Data(repeating: 0, count: 5 * 1024 * 1024 + 1) : Data("synthetic encrypted archive".utf8)
        return .init(data: data, headers: headers)
    }
}

actor F4CArchiveSaver: V15ArchiveArtifactSaving {
    enum Mode { case saved, cancelled }
    let mode: Mode
    init(mode: Mode) { self.mode = mode }
    func save(temporaryURL: URL, suggestedFilename: String) async throws -> V15ArchiveArtifactSaveResult {
        guard temporaryURL.lastPathComponent == suggestedFilename else { throw V15Failure(kind: .decoding, message: "fixture filename mismatch") }
        return mode == .saved ? .saved : .cancelled
    }
}
