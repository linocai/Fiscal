import Foundation

/// Deterministic, fully offline endpoint fixtures. Gallery and unit tests use
/// this instead of a legacy model, a running backend, or invented UI state.
actor V15FixtureTransport: V15Transporting {
    private var responses: [String: Data]
    private var requests: [V15Request] = []
    init(responses: [String: Data]) { self.responses = responses }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        guard request.method == "GET" else { throw V15Failure(kind: .offlineReadOnly, code: "offline_read_only", message: "离线夹具不允许写入。") }
        guard let data = responses[key(for: request)] ?? responses[request.path] else { throw V15Failure(kind: .transport, code: "fixture_missing", message: "缺少离线夹具。") }
        do { return try V15FixtureCodec.decoder.decode(Response.self, from: data) }
        catch { throw V15Failure(kind: .decoding, code: "fixture_decode_failed", message: "夹具不符合接口契约。") }
    }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data {
        requests.append(request)
        guard let data = responses[key(for: request)] ?? responses[request.path] else { throw V15Failure(kind: .transport, code: "fixture_missing", message: "缺少离线夹具。") }
        return data
    }
    private func key(for request: V15Request) -> String { request.query.isEmpty ? request.path : "\(request.path)?\(request.query.compactMap { guard let value = $0.value else { return nil }; return "\($0.name)=\(value)" }.joined(separator: "&"))" }
    func lastRequest() -> V15Request? { requests.last }
}

enum V15FixtureCodec {
    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) ?? basic.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Expected an ISO-8601 timestamp.")
        }
        return value
    }()
    static let encoder: JSONEncoder = { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }()

}
