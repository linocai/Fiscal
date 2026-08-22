import Foundation

/// Synthetic F3-G-only records. No user document bytes, real statement text,
/// file name/path, OCR image, or provider output enters this fixture surface.
public enum V15F3GFixtures {
    public static let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000007301")!
    public static let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000007302")!
    public static let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000007303")!
    public static let runID = UUID(uuidString: "00000000-0000-0000-0000-000000007304")!
    public static let rowID = UUID(uuidString: "00000000-0000-0000-0000-000000007305")!
    public static let unresolvedID = UUID(uuidString: "00000000-0000-0000-0000-000000007306")!
    public static let secondRowID = UUID(uuidString: "00000000-0000-0000-0000-000000007311")!
    public static let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000007307")!
    public static let matchedTransactionID = UUID(uuidString: "00000000-0000-0000-0000-000000007308")!
    @MainActor public static func services(route: String = "statement-import") -> V15Services { .init(transport: F3GTransport(mode: .route(route))) }
    static func batch(status: String = "review_required", version: Int = 5) -> String { "{\"id\":\"\(batchID)\",\"document_sha256\":\"\(String(repeating: "a", count: 64))\",\"byte_size\":512,\"page_count\":1,\"mime_type\":\"application/pdf\",\"display_name\":\"synthetic-statement.pdf\",\"currency\":\"CNY\",\"status\":\"\(status)\",\"latest_attempt_id\":\"\(attemptID)\",\"version\":\(version),\"created_at\":\"2026-08-16T00:00:00Z\",\"updated_at\":\"2026-08-16T00:00:00Z\",\"confirmed_at\":null,\"abandoned_at\":null}" }
    static func row(id: UUID, resolution: String, rowVersion: Int = 2, draftVersion: Int = 3) -> String { "{\"id\":\"\(id)\",\"row_number\":1,\"page_number\":1,\"row_version\":\(rowVersion),\"source_kind\":\"text\",\"evidence_text_masked\":\"合成交易 ••.••\",\"bounding_box\":{\"x\":0.08,\"y\":0.16,\"width\":0.76,\"height\":0.12},\"draft\":{\"id\":\"00000000-0000-0000-0000-000000007309\",\"resolution\":\"\(resolution)\",\"matched_transaction_id\":\(resolution == "match_existing" ? "\"\(matchedTransactionID)\"" : "null"),\"ignored_reason\":null,\"version\":\(draftVersion)},\"candidates\":[{\"id\":\"00000000-0000-0000-0000-000000007310\",\"candidate_kind\":\"existing_transaction\",\"transaction_id\":\"\(matchedTransactionID)\",\"transaction_date\":\"2026-08-15\",\"amount_minor\":1850}],\"final_create_draft_version\":\(resolution == "create_new" ? "1" : "null"),\"is_confirmed\":false}" }
    static func workbench(route: String, cursor: Int = 0, evidenceState: String? = nil) -> String { let status = route == "statement-import-partial" ? "partially_confirmed" : route == "statement-import-future-workbench" ? "future_status" : "ready_to_confirm"; let isResolutionRace = route == "statement-import-resolution-race"; let isResolutionReadback = route == "statement-import-resolution-readback" || route == "statement-import-resolution-readback-stale" || route == "statement-import-resolution-readback-missing"; let unresolved = (route == "statement-import-unresolved" || isResolutionRace) ? ",\(row(id: unresolvedID, resolution: "unresolved"))" : ""; let unavailabilityFilter = evidenceState == "unavailable"; let rows: String; if unavailabilityFilter { rows = "" } else if isResolutionReadback { if cursor == 0 { rows = row(id: rowID, resolution: "create_new") } else if route == "statement-import-resolution-readback-missing" { rows = row(id: secondRowID, resolution: "create_new") } else { rows = row(id: unresolvedID, resolution: route == "statement-import-resolution-readback-stale" ? "unresolved" : "create_new", draftVersion: route == "statement-import-resolution-readback-stale" ? 3 : 4) } } else { rows = (route == "statement-import-paged" || isResolutionRace) ? (cursor == 0 ? "\(row(id: rowID, resolution: "create_new"))\(unresolved)" : row(id: secondRowID, resolution: "create_new")) : "\(row(id: rowID, resolution: route == "statement-import-match" ? "match_existing" : "create_new"))\(unresolved)" }; let next = !unavailabilityFilter && ((route == "statement-import-paged" || isResolutionRace || isResolutionReadback) && cursor == 0) ? "1" : "null"; let batchVersion = isResolutionReadback ? 6 : 5; return "{\"batch_id\":\"\(batchID)\",\"batch_version\":\(batchVersion),\"status\":\"\(status)\",\"review_available\":true,\"validation_run_id\":\"\(runID)\",\"checks\":[{\"check_kind\":\"amount_consistency\",\"status\":\"passed\",\"evidence_row_ids\":[\"\(rowID)\"]}],\"rows\":[\(rows)],\"next_cursor\":\(next),\"source_unavailable_count\":\(route == "statement-import-source-unavailable" || unavailabilityFilter ? 1 : 0)}" }
    static func review() -> String { "{\"batch_id\":\"\(batchID)\",\"batch_version\":5,\"status\":\"review_required\",\"validation_run_id\":\"\(runID)\",\"provider_snapshot_id\":\"\(providerID)\",\"checks\":[],\"candidates\":[],\"drafts\":[],\"replay\":false}" }
    static func preview(future: Bool = false) -> String { "{\"batch_id\":\"\(batchID)\",\"batch_version\":5,\"status\":\"\(future ? "future_status" : "ready_to_confirm")\",\"selected_rows\":[{\"row_id\":\"\(rowID)\",\"expected_row_version\":2,\"expected_draft_version\":3,\"expected_final_create_draft_version\":1,\"resolution\":\"create_new\",\"is_confirmed\":false}],\"counts\":{\"selected\":1,\"create_new\":1,\"match_existing\":0,\"ignore_non_transaction\":0,\"ignore_intentional\":0,\"unresolved\":0,\"batch_unresolved\":0},\"amounts\":{\"known_create_minor\":1850,\"known_match_minor\":0,\"known_total_minor\":1850,\"unknown_selected_count\":0},\"checks\":[{\"check_kind\":\"amount_consistency\",\"status\":\"passed\"}],\"warnings\":[],\"request\":{\"expected_batch_version\":5,\"rows\":[{\"row_id\":\"\(rowID)\",\"expected_row_version\":2,\"expected_draft_version\":3,\"expected_final_create_draft_version\":1}]}}" }
    static func receipt(replay: Bool = false, partial: Bool = false) -> String { "{\"operation_id\":\"\(operationID)\",\"batch_id\":\"\(batchID)\",\"batch_version\":6,\"status\":\"\(partial ? "partially_confirmed" : "confirmed")\",\"confirmed_row_ids\":[\"\(rowID)\"],\"row_results\":[{\"row_id\":\"\(rowID)\",\"resolution\":\"create_new\",\"outcome\":\"applied\",\"transaction_id\":\"\(matchedTransactionID)\"}],\"created_count\":1,\"matched_count\":0,\"skipped_count\":0,\"result_detail_status\":\"complete\",\"replay\":\(replay)}" }
}

actor F3GTransport: V15Transporting {
    enum Mode: Equatable { case normal, permission, invalidFile, error, unresolved, sourceUnavailable, partial, providerUnknown, confirmConflict, unknown, receiptFailure, offline, futureBatch, futureWorkbench, futurePreview, paged, pageFailure, pageReadFailure, delayedProvider, delayedPreview, previewFailure, previewConflict, delayedConfirm, delayedResolution, resolutionUnknownReadback, resolutionReadbackMissing, resolutionReadbackPageFailure, resolutionReadbackStale
        static func route(_ value: String) -> Mode { switch value { case "statement-import-permission": .permission; case "statement-import-invalid": .invalidFile; case "statement-import-error": .error; case "statement-import-unresolved": .unresolved; case "statement-import-source-unavailable": .sourceUnavailable; case "statement-import-partial": .partial; case "statement-import-provider-unknown": .providerUnknown; case "statement-import-conflict": .confirmConflict; case "statement-import-unknown": .unknown; case "statement-import-receipt-error": .receiptFailure; case "statement-import-offline": .offline; case "statement-import-paged", "statement-import-paged-filtered": .paged; case "statement-import-page-error": .pageReadFailure; case "statement-import-future-workbench": .futureWorkbench; case "statement-import-preview-delayed": .delayedPreview; case "statement-import-preview-error": .previewFailure; case "statement-import-preview-conflict": .previewConflict; case "statement-import-confirm-delayed": .delayedConfirm; case "statement-import-resolution-delayed": .delayedResolution; case "statement-import-resolution-recovery": .resolutionUnknownReadback; default: .normal } }
    }
    struct Wire: Sendable, Equatable { let request: V15Request; let body: String }
    let mode: Mode; private var confirmCount = 0; private var previewCount = 0; private var providerCount = 0; private var resolutionCount = 0; private var statementReadCount = 0; private var pageReadCount = 0; private var wires: [Wire] = []; private var requests: [V15Request] = []; private var providerWireStarted = false; private var confirmWireStarted = false; private var resolutionWireStarted = false; private var resolutionCompleted = false
    init(mode: Mode) { self.mode = mode }
    func recordedWrites() -> [Wire] { wires }
    func recordedRequests() -> [V15Request] { requests }
    func hasProviderWireStarted() -> Bool { providerWireStarted }
    func hasConfirmWireStarted() -> Bool { confirmWireStarted }
    func hasResolutionWireStarted() -> Bool { resolutionWireStarted }
    func send<Response: Decodable & Sendable>(_ request: V15Request, body: JSONValue?) async throws -> Response {
        requests.append(request)
        if request.method != "GET" { wires.append(.init(request: request, body: body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? "")) }
        let decode: (String) throws -> Response = { try V15FixtureCodec.decoder.decode(Response.self, from: Data($0.utf8)) }
        let route: String = switch mode { case .unresolved: "statement-import-unresolved"; case .sourceUnavailable: "statement-import-source-unavailable"; case .partial: "statement-import-partial"; case .futureWorkbench: "statement-import-future-workbench"; case .paged, .pageFailure: "statement-import-paged"; case .delayedResolution: resolutionCompleted ? "statement-import-paged" : "statement-import-resolution-race"; case .resolutionUnknownReadback: resolutionCompleted ? "statement-import-resolution-readback" : "statement-import-resolution-race"; case .resolutionReadbackMissing: resolutionCompleted ? "statement-import-resolution-readback-missing" : "statement-import-resolution-race"; case .resolutionReadbackPageFailure: resolutionCompleted ? "statement-import-resolution-readback" : "statement-import-resolution-race"; case .resolutionReadbackStale: resolutionCompleted ? "statement-import-resolution-readback-stale" : "statement-import-resolution-race"; default: "statement-import" }
        switch (request.path, request.method) {
        case ("statement-imports", "POST"):
            if mode == .error { throw V15Failure(kind: .transport, message: "登记失败。") }; return try decode("\(V15F3GFixtures.batch(status: mode == .futureBatch ? "future_status" : "created", version: 1).dropLast()) ,\"duplicate\":false}")
        case ("statement-imports/\(V15F3GFixtures.batchID)", "GET"):
            statementReadCount += 1
            let recoveredResolution = resolutionCompleted && [.resolutionUnknownReadback, .resolutionReadbackMissing, .resolutionReadbackPageFailure, .resolutionReadbackStale].contains(mode)
            return try decode(V15F3GFixtures.batch(status: statementReadCount == 1 ? "extracting" : "ready_to_confirm", version: statementReadCount == 1 ? 2 : recoveredResolution ? 6 : 5))
        case ("statement-imports/\(V15F3GFixtures.batchID)/attempts", "POST"): return try decode("{\"id\":\"\(V15F3GFixtures.attemptID)\",\"attempt_number\":1,\"kind\":\"local_extraction\",\"status\":\"started\",\"error_code\":null,\"started_at\":\"2026-08-16T00:00:00Z\",\"completed_at\":null}")
        case ("statement-imports/\(V15F3GFixtures.batchID)/evidence", "POST"): return try decode("\(V15F3GFixtures.batch(status: "parsing", version: 3).dropLast()),\"attempt_id\":\"\(V15F3GFixtures.attemptID)\",\"evidence_sha256\":\"\(String(repeating: "b", count: 64))\",\"row_count\":1,\"duplicate\":false}")
        case ("statement-imports/\(V15F3GFixtures.batchID)/provider-attempts", "POST"):
            providerCount += 1; providerWireStarted = true; if mode == .delayedProvider && providerCount == 1 { try await Task.sleep(for: .seconds(2)) }; if mode == .providerUnknown && providerCount == 1 { throw V15Failure(kind: .responseUnknown, message: "解析响应未知。") }; return try decode("{\"provider_attempt_id\":\"\(V15F3GFixtures.providerID)\",\"attempt_id\":\"\(V15F3GFixtures.attemptID)\",\"provider_status\":\"succeeded\",\"candidate_count\":1,\"replay\":\(providerCount > 1),\"execution_scope\":\"request_bound\"}")
        case ("statement-imports/\(V15F3GFixtures.batchID)/validation-runs", "POST"): return try decode(V15F3GFixtures.review())
        case ("statement-imports/\(V15F3GFixtures.batchID)/review-workbench", "GET"):
            if mode == .pageFailure, request.query.contains(where: { $0.name == "cursor" && $0.value == "1" }) { throw V15Failure(kind: .transport, message: "下一页读取失败。") }
            let filterText = request.query.first(where: { $0.name == "filters" })?.value ?? "{}"
            guard let filterData = filterText.data(using: .utf8), let parsedFilter = try? JSONSerialization.jsonObject(with: filterData), let filterObject = parsedFilter as? [String: Any], Set(filterObject.keys).isSubset(of: Set(["resolution", "candidate_kind", "check_status", "evidence_state"])) else { throw V15Failure(kind: .decoding, code: "invalid_workbench_filters", message: "复核筛选字段必须使用服务端 snake_case。") }
            guard !filterObject.keys.contains("candidateKind"), !filterObject.keys.contains("checkStatus"), !filterObject.keys.contains("evidenceState") else { throw V15Failure(kind: .decoding, code: "invalid_workbench_filters", message: "复核筛选字段必须使用服务端 snake_case。") }
            let cursor = request.query.first(where: { $0.name == "cursor" })?.value.flatMap(Int.init) ?? 0
            if mode == .resolutionReadbackPageFailure, resolutionCompleted, cursor == 1 { throw V15Failure(kind: .transport, message: "恢复读取第二页失败。") }
            if mode == .resolutionUnknownReadback, resolutionCompleted, cursor == 1 { try await Task.sleep(for: .seconds(1)) }
            return try decode(V15F3GFixtures.workbench(route: route, cursor: cursor, evidenceState: filterObject["evidence_state"] as? String))
        case ("statement-imports/\(V15F3GFixtures.batchID)/review-workbench/pages/1", "GET"):
            pageReadCount += 1
            if mode == .pageReadFailure, pageReadCount == 1 { throw V15Failure(kind: .transport, message: "脱敏页面读取失败。") }
            return try decode("{\"batch_id\":\"\(V15F3GFixtures.batchID)\",\"page_number\":1,\"source_available\":true,\"source_kind\":\"text\",\"evidence_text_masked\":\"合成交易 ••.••\",\"bounding_boxes\":[{\"x\":0.08,\"y\":0.16,\"width\":0.76,\"height\":0.12}],\"rows\":[\(V15F3GFixtures.row(id: V15F3GFixtures.rowID, resolution: "create_new"))]}")
        case ("statement-imports/\(V15F3GFixtures.batchID)/confirmation-preview", "POST"):
            previewCount += 1
            // Gallery-only AX evidence needs a durable loading interval after
            // SwiftUI has completed presenting the confirmation sheet.
            if mode == .delayedPreview && previewCount == 1 { try await Task.sleep(for: .seconds(5)) }
            if mode == .previewFailure && previewCount == 1 { throw V15Failure(kind: .transport, message: "确认预览暂时不可用。") }
            if mode == .previewConflict && previewCount == 1 { throw V15Failure(kind: .conflict, code: "version_conflict", message: "行版本已变化，请重新获取预览。") }
            return try decode(V15F3GFixtures.preview(future: mode == .futurePreview))
        case ("statement-imports/\(V15F3GFixtures.batchID)/confirm", "POST"):
            confirmCount += 1; confirmWireStarted = true; if mode == .delayedConfirm && confirmCount == 1 { try await Task.sleep(for: .seconds(2)) }; if mode == .confirmConflict { throw V15Failure(kind: .conflict, code: "version_conflict", message: "行版本已变化。") }; if mode == .unknown && confirmCount == 1 { throw V15Failure(kind: .responseUnknown, message: "确认响应未知。") }; return try decode(V15F3GFixtures.receipt(partial: mode == .partial))
        case ("statement-imports/\(V15F3GFixtures.batchID)/confirmation-receipt", "GET"):
            if mode == .receiptFailure { throw V15Failure(kind: .transport, message: "收据读取失败。") }; return try decode(V15F3GFixtures.receipt(replay: true, partial: mode == .partial))
        case ("statement-imports/\(V15F3GFixtures.batchID)/rows/\(V15F3GFixtures.rowID)/draft-resolution", "PUT"), ("statement-imports/\(V15F3GFixtures.batchID)/rows/\(V15F3GFixtures.unresolvedID)/draft-resolution", "PUT"):
            resolutionCount += 1
            resolutionWireStarted = true
            if [.resolutionUnknownReadback, .resolutionReadbackMissing, .resolutionReadbackPageFailure, .resolutionReadbackStale].contains(mode), resolutionCount == 1 {
                // This simulates an applied server mutation whose response was
                // lost. Readback must find it through the unfiltered cursor.
                resolutionCompleted = true
                throw V15Failure(kind: .responseUnknown, message: "行处理响应未知。")
            }
            if mode == .delayedResolution && resolutionCount == 1 {
                try await Task.sleep(for: .seconds(2))
                resolutionCompleted = true
            }
            return try decode(V15F3GFixtures.review())
        default: throw V15Failure(kind: .transport, message: "F3-G fixture不支持 \(request.method) \(request.path)。")
        }
    }
    func sendNoContent(_ request: V15Request, body: JSONValue?) async throws { requests.append(request); if request.method != "GET" { wires.append(.init(request: request, body: body.flatMap { try? String(data: V15BodyEncoder.data($0), encoding: .utf8) } ?? "")) } }
    func fetchArtifact(_ request: V15Request, accept: String) async throws -> Data { throw V15Failure(kind: .transport, message: "F3-G 不读取远端文件。") }
}
