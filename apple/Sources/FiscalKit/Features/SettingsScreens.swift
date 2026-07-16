import SwiftUI

public struct IOSSettingsScreen: View {
  @Bindable var model: AISettingsModel
  public init(model: AISettingsModel) { self.model = model }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        settingsNotice
        section("AI 自动记账") { AISettingsCard(model: model, compact: true) }
      }.padding(16).padding(.bottom, 100)
    }.background(FiscalColor.iOSBackground).navigationTitle("设置")
      .task { if model.phase == .idle { await model.load() } }
  }
  @ViewBuilder private var settingsNotice: some View {
    if let message = model.message {
      Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption)
        .foregroundStyle(FiscalColor.expense).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(FiscalColor.expense.opacity(0.08), in: .rect(cornerRadius: 12))
    }
  }
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline).padding(.horizontal, 3); content() }
  }
}

public struct AISettingsCard: View {
  @Bindable var model: AISettingsModel
  let compact: Bool
  public init(model: AISettingsModel, compact: Bool = false) { self.model = model; self.compact = compact }
  public var body: some View {
    FiscalCard(radius: compact ? 18 : 15) {
      VStack(alignment: .leading, spacing: 15) {
        if model.phase == .loading && model.settings == nil { ProgressView("读取安全规则…").frame(maxWidth: .infinity).padding(20) }
        else {
          Toggle(isOn: $model.autoExecuteEnabled) {
            VStack(alignment: .leading, spacing: 3) { Text("启用自动记账").font(.subheadline.weight(.semibold)); Text(providerDetail).font(.caption).foregroundStyle(FiscalColor.tertiary) }
          }.toggleStyle(FiscalSwitchToggleStyle())
          if model.autoExecuteEnabled {
            Divider().opacity(0.35)
            optionRow("自动记账上限") {
              Picker("自动记账上限", selection: $model.autoExecuteLimitMinor) {
                ForEach(AISettingsModel.limitOptions, id: \.self) { value in Text(Money(minorUnits: value).formatted()).tag(value) }
              }.labelsHidden().pickerStyle(.segmented)
            }
            optionRow("最低置信度") {
              Picker("最低置信度", selection: $model.minimumConfidenceBps) {
                ForEach(AISettingsModel.confidenceOptions, id: \.self) { value in Text("\(value / 100)%").tag(value) }
              }.labelsHidden().pickerStyle(.segmented)
            }
          }
          Text("仅普通收入或支出、字段完整且满足服务端安全规则时自动执行；客户端设置不能放宽 ¥1,000 与 90% 的硬边界。")
            .font(.caption).foregroundStyle(FiscalColor.tertiary).fixedSize(horizontal: false, vertical: true)
          Button(model.isSaving ? "保存中…" : "保存 AI 设置") { Task { await model.save() } }
            .buttonStyle(FiscalActionButtonStyle()).disabled(model.isSaving || model.settings == nil)
            .accessibilityIdentifier("ai.settings.save")
        }
      }
    }
  }
  private var providerDetail: String {
    guard let settings = model.settings else { return "服务端配置是最终安全边界" }
    if !settings.providerConfigured { return "AI Provider 尚未配置，自动执行不会生效" }
    return settings.effectiveAutoExecute ? "已按服务端安全规则生效" : "当前不会自动执行"
  }
  private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption.weight(.semibold)).foregroundStyle(FiscalColor.secondary); content() }
  }
}

#if os(macOS)
public struct MacSettingsScreen: View {
  @Bindable var model: AISettingsModel
  public init(model: AISettingsModel) { self.model = model }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 15) {
        HStack { Text("设置").font(.system(size: 23, weight: .bold)); Spacer(); if let settings = model.settings { Text(settings.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(FiscalColor.tertiary) } }
        Text("AI 自动记账").font(.headline)
        AISettingsCard(model: model)
        if let message = model.message { Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(FiscalColor.expense) }
      }.frame(maxWidth: 660).padding(22).frame(maxWidth: .infinity, alignment: .top)
    }.background(FiscalColor.macBackground).task { if model.phase == .idle { await model.load() } }
  }
}
#endif
