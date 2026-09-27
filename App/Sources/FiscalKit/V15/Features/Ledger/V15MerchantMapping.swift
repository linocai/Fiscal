import Foundation
import Observation
import SwiftUI

struct V15Merchant: Codable, Sendable {
    let id: UUID
    let name: String
    let aliases: [String]
}

struct V15MerchantMapping: Codable, Sendable {
    let merchant: V15Merchant
    let mappingVersion: Int
    enum CodingKeys: String, CodingKey { case merchant, mappingVersion = "mapping_version" }
}

struct V15MerchantMappingState: Codable, Sendable {
    let mapping: V15MerchantMapping?
    let suggestedMerchant: V15Merchant?
    enum CodingKeys: String, CodingKey { case mapping, suggestedMerchant = "suggested_merchant" }
}

struct V15MerchantMappingRequest: Codable, Sendable {
    let merchantName: String
    let aliases: [String]
    let expectedMappingVersion: Int?
    enum CodingKeys: String, CodingKey {
        case merchantName = "merchant_name", aliases, expectedMappingVersion = "expected_mapping_version"
    }
}

struct V15MerchantMappingReceipt: Codable, Sendable {
    let action: String
    let mapping: V15MerchantMapping?
}

@MainActor @Observable
final class V15MerchantMappingModel {
    var name = ""
    var aliasesText = ""
    private(set) var mapping: V15MerchantMapping?
    private(set) var suggestion: V15Merchant?
    private(set) var loaded = false
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var hasUnknownOutcome = false
    private(set) var hasConfirmedWrite = false
    private var generation: UInt64 = 0
    private var attempt: Attempt?
    private let services: V15Services
    private let transactionID: UUID
    private let readOnly: Bool
    private enum Intent { case confirm(V15MerchantMappingRequest), release(Int) }
    private struct Attempt { let key: UUID; let intent: Intent }

    init(services: V15Services, transactionID: UUID, readOnly: Bool = false) {
        self.services = services; self.transactionID = transactionID; self.readOnly = readOnly
    }

    var canEdit: Bool { loaded && !isWorking && !hasUnknownOutcome && !readOnly && services.offlineSnapshotAt == nil }
    var canSave: Bool { canEdit && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load() async {
        guard !isWorking, !hasUnknownOutcome else { return }
        generation &+= 1; let current = generation
        isWorking = true; loaded = false; message = nil
        defer { if current == generation { isWorking = false } }
        do {
            let state = try await services.ledger.merchantMapping(transactionID: transactionID)
            guard current == generation else { return }
            apply(state)
        } catch {
            guard current == generation else { return }
            message = (error as? V15Failure)?.message ?? "商户读取失败，请重试。"
        }
    }

    func save() async {
        guard canSave else { return }
        let aliases = aliasesText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        attempt = .init(key: UUID(), intent: .confirm(.init(merchantName: name.trimmingCharacters(in: .whitespacesAndNewlines), aliases: aliases, expectedMappingVersion: mapping?.mappingVersion)))
        await submit()
    }

    func release() async {
        guard canEdit, let mapping else { return }
        attempt = .init(key: UUID(), intent: .release(mapping.mappingVersion))
        await submit()
    }

    func retry() async { guard hasUnknownOutcome else { return }; await submit() }

    func finishEditing() {
        guard hasConfirmedWrite else { return }
        hasConfirmedWrite = false
        services.notifyConfirmedWrite()
    }

    private func submit() async {
        guard !isWorking, let attempt else { return }
        isWorking = true; message = nil
        defer { isWorking = false }
        do {
            switch attempt.intent {
            case .confirm(let request):
                _ = try await services.ledger.confirmMerchant(transactionID: transactionID, request: request, key: attempt.key)
            case .release(let version):
                _ = try await services.ledger.releaseMerchant(transactionID: transactionID, version: version, key: attempt.key)
            }
            self.attempt = nil; hasUnknownOutcome = false; loaded = false
            // iOS refreshes the underlying transaction detail on this signal.
            // Defer it until dismissal so the editor and its receipt stay alive.
            hasConfirmedWrite = true
            // An idempotent receipt may be older than another editor's change.
            // Only a fresh read can authorize another correction.
            do {
                apply(try await services.ledger.merchantMapping(transactionID: transactionID))
                message = "商户信息已保存。"
            } catch { message = "已保存，但刷新失败；请重新读取后再编辑。" }
        } catch {
            let failure = (error as? V15Failure) ?? V15Failure(kind: .transport, message: "保存结果暂时不明。")
            hasUnknownOutcome = V15LedgerCreateService.outcomeMayBeUnknown(failure)
            if hasUnknownOutcome {
                message = "保存结果暂时不明。请重试同一次操作，确认前不能修改内容。"
            } else {
                self.attempt = nil
                if failure.kind == .conflict { loaded = false }
                message = failure.kind == .conflict ? "商户信息已变化，请重新读取后再决定。" : failure.message
            }
        }
    }

    private func apply(_ state: V15MerchantMappingState) {
        mapping = state.mapping; suggestion = state.suggestedMerchant
        let merchant = state.mapping?.merchant ?? state.suggestedMerchant
        name = merchant?.name ?? ""; aliasesText = ""
        loaded = true
    }
}

/// One small transaction-level editor is shared by both native workspaces.
struct V15MerchantMappingButton: View {
    let services: V15Services
    let transaction: V15Transaction
    @State private var presented = false

    var body: some View {
        V15ActionButton("商户识别", kind: .secondary) { presented = true }
            .accessibilityIdentifier("v240.merchant.open")
            .sheet(isPresented: $presented) {
                V15MerchantMappingEditor(services: services, transaction: transaction)
            }
    }
}

private struct V15MerchantMappingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: V15MerchantMappingModel
    init(services: V15Services, transaction: V15Transaction) {
        _model = State(initialValue: V15MerchantMappingModel(services: services, transactionID: transaction.id, readOnly: transaction.voidedAt != nil))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let mapping = model.mapping { Text("当前商户：\(mapping.merchant.name)") }
                    else if model.suggestion != nil { Text("已识别到商户，确认后用于分析。") }
                    else { Text("为这笔交易确认商户，不改变原始账目。") }
                    if let merchant = model.mapping?.merchant ?? model.suggestion, !merchant.aliases.isEmpty {
                        Text("已有别名：\(merchant.aliases.joined(separator: "、"))").font(.caption)
                    }
                    TextField("商户名称", text: $model.name)
                        .accessibilityIdentifier("v240.merchant.name")
                    TextField("新增识别别名（每行一个）", text: $model.aliasesText, axis: .vertical)
                        .lineLimit(2...4)
                    Text("别名用于匹配同名交易；已有别名会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!model.canEdit)
                Section {
                    if let message = model.message { Text(message).accessibilityIdentifier("v240.merchant.feedback") }
                    if model.isWorking { ProgressView() }
                    if model.hasUnknownOutcome {
                        Button("重试同一次操作") { Task { await model.retry() } }.disabled(model.isWorking)
                    } else {
                        Button("确认商户") { Task { await model.save() } }.disabled(!model.canSave)
                            .accessibilityIdentifier("v240.merchant.save")
                        if model.mapping != nil {
                            Button("解除这笔交易的商户关联", role: .destructive) { Task { await model.release() } }
                                .disabled(!model.canEdit)
                        }
                        Button("重新读取") { Task { await model.load() } }.disabled(model.isWorking)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("商户识别")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(model.isWorking || model.hasUnknownOutcome) } }
            .interactiveDismissDisabled(model.isWorking || model.hasUnknownOutcome)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 400)
        #endif
        .task { await model.load() }
        .onDisappear { model.finishEditing() }
    }
}
