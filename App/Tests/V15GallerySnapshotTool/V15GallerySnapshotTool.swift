import AppKit
import FiscalKit
import SwiftUI

@main
private struct V15GallerySnapshotTool {
    @MainActor
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["FISCAL_V15_GALLERY_SCREENSHOT_DIR"] ?? "../archive/releases/v1.5.0/qa/frontend/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        if environment["FISCAL_V15_SNAPSHOT_SCOPE"] == "f4b" {
            try renderF4B(to: output)
            return
        }
        if environment["FISCAL_V15_SNAPSHOT_SCOPE"] == "f4c" {
            try renderF4C(to: output)
            return
        }

        for fixture in V15GalleryFixture.allCases {
            try render(V15GalleryShell(fixture: fixture, density: .comfortable), to: output.appendingPathComponent("macos-\(fixture.id)-light.png"), colorScheme: .light, size: CGSize(width: 1240, height: 760))
            try render(V15GalleryShell(fixture: fixture, density: .compact), to: output.appendingPathComponent("macos-\(fixture.id)-dark-compact.png"), colorScheme: .dark, size: CGSize(width: 900, height: 680))
        }
        try render(V15GalleryShell(fixture: .preview, density: .comfortable), to: output.appendingPathComponent("macos-preview-dark-comfortable.png"), colorScheme: .dark, size: CGSize(width: 1240, height: 760))
        let f1ARecord = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f1a-route", "record-valid"])
        try render(f1ARecord, to: output.appendingPathComponent("f1a-macos-record-light.png"), colorScheme: .light, size: CGSize(width: 1240, height: 760))
        try render(f1ARecord, to: output.appendingPathComponent("f1a-macos-record-dark.png"), colorScheme: .dark, size: CGSize(width: 1240, height: 760))
        try render(f1ARecord, to: output.appendingPathComponent("f1a-macos-record-ax5.png"), colorScheme: .light, size: CGSize(width: 1240, height: 980), dynamicTypeSize: .accessibility5)
        let f1BLedger = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f1b-route", "ledger"])
        try render(f1BLedger, to: output.appendingPathComponent("f1b-macos-ledger-light.png"), colorScheme: .light, size: CGSize(width: 1240, height: 760))
        try render(f1BLedger, to: output.appendingPathComponent("f1b-macos-ledger-dark.png"), colorScheme: .dark, size: CGSize(width: 1240, height: 760))
        try render(f1BLedger, to: output.appendingPathComponent("f1b-macos-ledger-ax5.png"), colorScheme: .light, size: CGSize(width: 1240, height: 980), dynamicTypeSize: .accessibility5)
        let f1BDetail = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f1b-route", "ledger-detail"])
        try render(f1BDetail, to: output.appendingPathComponent("f1b-macos-ledger-detail-light.png"), colorScheme: .light, size: CGSize(width: 1240, height: 760))
        try render(f1BDetail, to: output.appendingPathComponent("f1b-macos-ledger-detail-dark.png"), colorScheme: .dark, size: CGSize(width: 1240, height: 760))
        let f1CMaster = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f1c-route", "master"])
        try render(f1CMaster, to: output.appendingPathComponent("f1c-macos-master-light.png"), colorScheme: .light, size: CGSize(width: 1240, height: 760))
        try render(f1CMaster, to: output.appendingPathComponent("f1c-macos-master-dark.png"), colorScheme: .dark, size: CGSize(width: 1240, height: 760))
        try render(f1CMaster, to: output.appendingPathComponent("f1c-macos-master-ax5.png"), colorScheme: .light, size: CGSize(width: 1240, height: 980), dynamicTypeSize: .accessibility5)
        let f2CRoutes: [(route: String, style: String, colorScheme: ColorScheme, size: CGSize, dynamicTypeSize: DynamicTypeSize)] = [
            ("today", "light-comfortable", .light, CGSize(width: 1240, height: 760), .large),
            ("today-zero-future", "dark-compact", .dark, CGSize(width: 820, height: 900), .large),
            ("today-long", "light-comfortable", .light, CGSize(width: 1240, height: 760), .large),
            ("today-long", "dark-compact", .dark, CGSize(width: 820, height: 900), .accessibility5),
            ("today-offline", "light-comfortable", .light, CGSize(width: 1240, height: 760), .large),
            ("today-offline", "dark-compact", .dark, CGSize(width: 820, height: 900), .large),
            ("today-conflict", "light-comfortable", .light, CGSize(width: 1240, height: 760), .large),
            ("today-conflict", "dark-compact", .dark, CGSize(width: 820, height: 900), .large),
            ("today-scope-error", "light-comfortable", .light, CGSize(width: 1240, height: 760), .large),
            ("today-scope-error", "dark-compact", .dark, CGSize(width: 820, height: 900), .large),
            ("today-unknown", "light-comfortable", .light, CGSize(width: 1240, height: 760), .large),
            ("today-unknown", "dark-compact", .dark, CGSize(width: 820, height: 900), .large)
        ]
        for scene in f2CRoutes {
            let route = scene.route
            let today = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f2c-route", route])
            try render(today, to: output.appendingPathComponent("f2c-macos-\(route)-\(scene.style).png"), colorScheme: scene.colorScheme, size: scene.size, dynamicTypeSize: scene.dynamicTypeSize)
        }
        let f3ARoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("timeline", "light", .light, CGSize(width: 1240, height: 760), .large),
            ("timeline", "dark", .dark, CGSize(width: 900, height: 760), .large),
            ("timeline", "ax5", .light, CGSize(width: 1240, height: 980), .accessibility5),
            ("timeline-empty", "empty", .light, CGSize(width: 1240, height: 760), .large),
            ("timeline-page-error", "page-error", .dark, CGSize(width: 900, height: 760), .large),
            ("timeline-conflict", "conflict", .light, CGSize(width: 1240, height: 760), .large),
            ("timeline-offline", "offline", .dark, CGSize(width: 900, height: 760), .accessibility5)
        ]
        for (route, style, scheme, size, type) in f3ARoutes {
            let timeline = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3a-route", route])
            try render(timeline, to: output.appendingPathComponent("f3a-macos-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type)
        }
        let f3B1Routes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("credit", "light-spine", .light, CGSize(width: 1240, height: 760), .large),
            ("credit", "dark-spine", .dark, CGSize(width: 900, height: 760), .large),
            ("credit", "ax5", .light, CGSize(width: 1240, height: 980), .accessibility5),
            ("credit-expired", "preview-expired", .dark, CGSize(width: 900, height: 760), .large),
            ("credit-disabled", "preview-disabled", .light, CGSize(width: 1240, height: 760), .large),
            ("credit-conflict", "conflict", .dark, CGSize(width: 900, height: 760), .large),
            ("credit-offline", "offline", .light, CGSize(width: 1240, height: 760), .accessibility5),
            ("credit-page-error", "page-error", .dark, CGSize(width: 900, height: 760), .large)
        ]
        for (route, style, scheme, size, type) in f3B1Routes {
            let credit = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3b1-route", route])
            try render(credit, to: output.appendingPathComponent("f3b1-macos-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type)
        }
        let f3B2Routes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("installments", "light-spine", .light, CGSize(width: 1440, height: 900), .large),
            ("installments", "dark-spine", .dark, CGSize(width: 1180, height: 820), .large),
            ("installments", "ax5", .light, CGSize(width: 1440, height: 1080), .accessibility5),
            ("installments-offline", "offline", .dark, CGSize(width: 1180, height: 900), .accessibility5),
            ("installments-page-error", "page-error", .light, CGSize(width: 1440, height: 900), .large),
            ("installments-update-unknown-confirmed", "put-readback", .dark, CGSize(width: 1180, height: 820), .large),
            ("installments-command-unknown", "command-recovery", .light, CGSize(width: 1440, height: 900), .large)
        ]
        for (route, style, scheme, size, type) in f3B2Routes {
            let installments = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3b2-route", route])
            try render(installments, to: output.appendingPathComponent("f3b2-macos-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type)
        }
        let f3CRoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("reimbursements-claim-new", "claim-new", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-claim-reasons", "claim-reasons", .dark, CGSize(width: 1180, height: 820), .large),
            ("reimbursements-receipt-loading", "receipt-loading", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-receipt-empty", "receipt-empty", .dark, CGSize(width: 1180, height: 820), .large),
            ("reimbursements-receipt-retry", "receipt-retry", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-invalid-valid", "invalid-valid", .dark, CGSize(width: 1180, height: 820), .large),
            ("reimbursements-preview", "preview", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-conflict", "conflict", .dark, CGSize(width: 1180, height: 820), .large),
            ("reimbursements-success", "success", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-partial", "partial", .dark, CGSize(width: 1180, height: 820), .large),
            ("reimbursements-offline", "offline", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-long", "ax5", .dark, CGSize(width: 1440, height: 1080), .accessibility5),
            ("reimbursements-actions-draft", "action-matrix", .light, CGSize(width: 1440, height: 900), .large),
            ("reimbursements-receipt-replace", "receipt-replace", .dark, CGSize(width: 1180, height: 820), .large),
            ("reimbursements-receipt-refresh-failure", "partial-success", .light, CGSize(width: 1440, height: 900), .large)
        ]
        for (route, style, scheme, size, type) in f3CRoutes {
            let reimbursements = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3c-route", route])
            try render(reimbursements, to: output.appendingPathComponent("f3c-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type)
        }
        let f3DRoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("cash-flow", "light-spine", .light, CGSize(width: 1440, height: 900), .large),
            ("cash-flow", "dark-spine", .dark, CGSize(width: 1180, height: 820), .large),
            ("cash-flow-long", "ax5", .light, CGSize(width: 1440, height: 1080), .accessibility5),
            ("cash-flow-offline", "offline", .dark, CGSize(width: 1180, height: 900), .accessibility5),
            ("cash-flow-history", "history", .light, CGSize(width: 1440, height: 900), .large),
            ("cash-flow-edit", "occurrence-future", .dark, CGSize(width: 1180, height: 820), .large),
            ("cash-flow-settle", "settle-transfer", .light, CGSize(width: 1440, height: 900), .large),
            ("cash-flow-system", "system-fact", .dark, CGSize(width: 1180, height: 820), .large),
            ("cash-flow-conflict", "conflict", .light, CGSize(width: 1440, height: 900), .large),
            ("cash-flow-unknown", "unknown", .dark, CGSize(width: 1180, height: 820), .large)
        ]
        for (route, style, scheme, size, type) in f3DRoutes {
            let cashFlow = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3d-route", route])
            try render(cashFlow, to: output.appendingPathComponent("f3d-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type)
        }
        let f3ERoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("reconciliation", "light-spine", .light, CGSize(width: 1440, height: 900), .large),
            ("reconciliation", "dark-spine", .dark, CGSize(width: 1180, height: 820), .large),
            ("reconciliation-long", "ax5", .light, CGSize(width: 1440, height: 1080), .accessibility5),
            ("reconciliation-offline", "offline", .dark, CGSize(width: 1180, height: 900), .accessibility5),
            ("reconciliation-empty", "empty", .light, CGSize(width: 1440, height: 900), .large),
            ("reconciliation-error", "service-error", .dark, CGSize(width: 1180, height: 820), .large),
            ("reconciliation-diagnosis-error", "diagnosis-error", .light, CGSize(width: 1440, height: 900), .large),
            ("reconciliation-editor", "editor-confirm", .dark, CGSize(width: 1180, height: 820), .large),
            ("reconciliation-conflict", "conflict", .light, CGSize(width: 1440, height: 900), .large),
            ("reconciliation-unknown", "keyless-unknown", .dark, CGSize(width: 1180, height: 820), .large),
            ("reconciliation-attention-disabled", "attention-disabled", .light, CGSize(width: 1440, height: 900), .large),
            ("reconciliation-attention-unknown", "attention-unknown", .dark, CGSize(width: 1180, height: 820), .large),
            ("reconciliation-mutation-error", "mutation-error", .dark, CGSize(width: 1180, height: 820), .large),
            ("reconciliation-partial-refresh", "partial-refresh", .light, CGSize(width: 1440, height: 900), .large)
        ]
        for (route, style, scheme, size, type) in f3ERoutes {
            let reconciliation = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3e-route", route])
            try render(reconciliation, to: output.appendingPathComponent("f3e-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type)
        }
        let f3FRoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("ai-proposals", "light-spine", .light, CGSize(width: 1440, height: 900), .large),
            ("ai-proposals", "dark-compact", .dark, CGSize(width: 1120, height: 760), .large),
            ("ai-review", "review-sheet", .light, CGSize(width: 1440, height: 980), .large),
            ("ai-long", "ax5-long", .dark, CGSize(width: 1440, height: 1080), .accessibility5),
            ("ai-offline", "offline", .light, CGSize(width: 1180, height: 820), .accessibility5),
            ("ai-empty", "empty", .light, CGSize(width: 1440, height: 900), .large),
            ("ai-error", "service-error", .dark, CGSize(width: 1180, height: 820), .large),
            ("ai-field-error", "field-error", .light, CGSize(width: 1440, height: 900), .large),
            ("ai-conflict", "conflict", .dark, CGSize(width: 1180, height: 820), .large),
            ("ai-response-unknown", "response-unknown", .light, CGSize(width: 1440, height: 900), .large),
            ("ai-response-unknown-read-failure", "response-unknown-read-failure", .dark, CGSize(width: 1180, height: 820), .large),
            ("ai-page-error", "page-error", .light, CGSize(width: 1440, height: 900), .large),
            ("ai-cash-flow", "cash-flow-review", .light, CGSize(width: 1440, height: 980), .large),
            ("ai-create-unknown-settings-transport-after-safe", "stable-create-recovery", .light, CGSize(width: 1440, height: 980), .large),
            ("ai-settings-violation", "d3-contract-error", .dark, CGSize(width: 1180, height: 820), .large)
        ]
        for (route, style, scheme, size, type) in f3FRoutes {
            let proposals = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3f-route", route])
            try render(proposals, to: output.appendingPathComponent("f3f-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type, settlingDelay: 1.5)
        }
        let f3GRoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("statement-import-intake", "intake", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import", "dark-workbench", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-page", "masked-page", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-page-error", "page-error", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-resolution-recovery", "resolution-readback", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-review", "review", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-preview", "preview", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-preview-error", "preview-retry", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-unresolved", "unresolved", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-source-unavailable", "source-unavailable", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-partial", "partial-receipt", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-unknown", "response-unknown", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-provider-unknown", "request-bound-cancel", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-paged-filtered", "pagination-filter", .light, CGSize(width: 1440, height: 900), .large),
            ("statement-import-future-workbench", "future-status-read-only", .dark, CGSize(width: 1180, height: 820), .large),
            ("statement-import-offline", "offline-ax5", .light, CGSize(width: 1440, height: 980), .accessibility5)
        ]
        for (route, style, scheme, size, type) in f3GRoutes {
            let statementImport = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f3g-route", route])
            try render(statementImport, to: output.appendingPathComponent("f3g-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type, settlingDelay: 8)
        }
        let f4ARoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("reports", "report-light", .light, CGSize(width: 1440, height: 900), .large),
            ("reports", "report-dark", .dark, CGSize(width: 1180, height: 820), .large),
            ("reports", "report-ax5", .light, CGSize(width: 1440, height: 1080), .accessibility5),
            ("reports-empty", "empty", .light, CGSize(width: 1440, height: 900), .large),
            ("reports-loading", "loading", .dark, CGSize(width: 1180, height: 820), .large),
            ("reports-error", "error", .light, CGSize(width: 1440, height: 900), .large),
            ("reports-offline", "offline", .dark, CGSize(width: 1180, height: 820), .accessibility5),
            ("reports-unknown", "unknown", .light, CGSize(width: 1440, height: 900), .large)
        ]
        for (route, style, scheme, size, type) in f4ARoutes {
            let reports = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f4a-route", route])
            try render(reports, to: output.appendingPathComponent("f4a-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type, settlingDelay: route == "reports-loading" ? 0.2 : 0.8)
        }
        try renderF4B(to: output)
        try renderF4C(to: output)
    }

    @MainActor
    private static func renderF4B(to output: URL) throws {
        let f4BRoutes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("reports", "export-controls-light", .light, CGSize(width: 1440, height: 900), .large),
            ("reports", "export-controls-dark", .dark, CGSize(width: 1180, height: 820), .large),
            ("reports-offline", "export-disabled-ax5", .light, CGSize(width: 1440, height: 1080), .accessibility5)
        ]
        for (route, style, scheme, size, type) in f4BRoutes {
            let reports = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f4b-route", route])
            try render(reports, to: output.appendingPathComponent("f4b-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type, settlingDelay: 0.8)
        }
    }

    @MainActor
    private static func renderF4C(to output: URL) throws {
        let routes: [(String, String, ColorScheme, CGSize, DynamicTypeSize)] = [
            ("archive", "security-light", .light, CGSize(width: 1180, height: 820), .large),
            ("archive", "security-dark", .dark, CGSize(width: 1180, height: 820), .large),
            ("archive-loading", "creating", .light, CGSize(width: 1180, height: 820), .large),
            ("archive-error", "error", .dark, CGSize(width: 1180, height: 820), .large),
            ("archive-unknown", "unknown", .light, CGSize(width: 1180, height: 820), .large),
            ("archive-offline", "offline-ax5", .dark, CGSize(width: 1180, height: 980), .accessibility5)
        ]
        for (route, style, scheme, size, type) in routes {
            let security = V15GalleryShell(arguments: ["V15GallerySnapshotTool", "--v15-f4c-route", route])
            try render(security, to: output.appendingPathComponent("f4c-mac-\(style).png"), colorScheme: scheme, size: size, dynamicTypeSize: type, settlingDelay: route == "archive-loading" ? 0.2 : 0.8)
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL, colorScheme: ColorScheme, size: CGSize, dynamicTypeSize: DynamicTypeSize = .large, settlingDelay: TimeInterval = 0.4) throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, colorScheme).environment(\.dynamicTypeSize, dynamicTypeSize))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(v15: colorScheme == .dark ? 0x0F1615 : 0xFFFFFF)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        if settlingDelay > 0 { RunLoop.main.run(until: Date().addingTimeInterval(settlingDelay)) }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.orderOut(nil)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}

private extension NSColor {
    convenience init(v15 value: UInt) {
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
