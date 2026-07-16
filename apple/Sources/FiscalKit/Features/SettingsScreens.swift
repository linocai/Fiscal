import SwiftUI
#if os(iOS)
  import UIKit
#endif

#if os(iOS)
public struct IOSSettingsScreen: View {
  @Bindable var model: AISettingsModel
  @State private var capture = CaptureAuthorizationModel()
  @Environment(\.openURL) private var openURL
  public init(model: AISettingsModel) { self.model = model }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        settingsNotice
        section("快捷录入") {
          VStack(spacing: 12) {
            CaptureSourceSettingsCard(model: model, compact: true)
            DeviceCaptureSettingsCard(model: capture, openSystemSettings: openSystemSettings)
          }
        }
        section("AI 自动记账") { AISettingsCard(model: model, compact: true) }
      }.padding(16).padding(.bottom, 100)
    }.background(FiscalColor.iOSBackground).navigationTitle("设置")
      .task { if model.phase == .idle { await model.load() } }
      .task { await capture.refresh() }
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
  private func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    openURL(url)
  }
}
#endif

public struct CaptureSourceSettingsCard: View {
  @Bindable var model: AISettingsModel
  let compact: Bool
  public init(model: AISettingsModel, compact: Bool = false) {
    self.model = model; self.compact = compact
  }
  public var body: some View {
    FiscalCard(radius: compact ? 18 : 15) {
      VStack(alignment: .leading, spacing: 15) {
        Toggle(isOn: $model.shortcutTextSourceEnabled) {
          settingLabel("快捷指令文本", "允许 Siri 与快捷指令提交自然语言记账")
        }.toggleStyle(FiscalSwitchToggleStyle())
        Divider().opacity(0.35)
        Toggle(isOn: $model.ocrSourceEnabled) {
          settingLabel("截图 OCR", "图片只在 iPhone 端识别，服务器仅接收文字")
        }.toggleStyle(FiscalSwitchToggleStyle())
        Text("关闭来源后，新请求会被服务器拒绝；解析中的提案也不会自动落账。")
          .font(.caption).foregroundStyle(FiscalColor.tertiary)
        Button(model.isSaving ? "保存中…" : "保存快捷录入设置") {
          Task { await model.save() }
        }.buttonStyle(FiscalActionButtonStyle(.secondary))
          .disabled(model.isSaving || model.settings == nil)
          .accessibilityIdentifier("capture.settings.save")
      }
    }
  }
  private func settingLabel(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.subheadline.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(FiscalColor.tertiary)
    }
  }
}

#if os(iOS)
  public struct DeviceCaptureSettingsCard: View {
    @Bindable var model: CaptureAuthorizationModel
    let openSystemSettings: () -> Void
    public init(
      model: CaptureAuthorizationModel,
      openSystemSettings: @escaping () -> Void
    ) {
      self.model = model; self.openSystemSettings = openSystemSettings
    }
    public var body: some View {
      FiscalCard(radius: 18) {
        VStack(alignment: .leading, spacing: 15) {
          statusRow("最新截图访问", model.photosTitle, symbol: "photo.on.rectangle") {
            if model.canRequestPhotos {
              Button("请求访问") { Task { await model.requestPhotos() } }
            }
          }
          Divider().opacity(0.35)
          statusRow("记账结果通知", model.notificationTitle, symbol: "bell.badge") {
            if model.canRequestNotifications {
              Button("允许通知") { Task { await model.requestNotifications() } }
            }
          }
          if model.needsSystemSettings {
            Button("打开系统设置", systemImage: "gear") { openSystemSettings() }
              .buttonStyle(FiscalActionButtonStyle(.secondary))
          }
          Divider().opacity(0.35)
          VStack(alignment: .leading, spacing: 8) {
            Label("Back Tap 需手工配置", systemImage: "hand.tap")
              .font(.subheadline.weight(.semibold))
            Text("推荐在快捷指令中先执行“截屏”，再把图片传给“用截图记账”；随后到系统设置 → 辅助功能 → 触控 → 轻点背面绑定该快捷指令。Fiscal 无法读取或替你修改 Back Tap 状态。")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }

    private func statusRow<Actions: View>(
      _ title: String,
      _ status: String,
      symbol: String,
      @ViewBuilder actions: () -> Actions
    ) -> some View {
      HStack(spacing: 12) {
        FiscalIconTile(symbol, color: FiscalColor.accent)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.subheadline.weight(.semibold))
          Text(status).font(.caption).foregroundStyle(FiscalColor.tertiary)
        }
        Spacer()
        actions().font(.caption.weight(.semibold)).buttonStyle(.plain)
          .foregroundStyle(FiscalColor.accent)
      }
    }
  }
#endif

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
        Text("快捷录入来源").font(.headline).padding(.top, 6)
        CaptureSourceSettingsCard(model: model)
        Text("照片权限、通知与 Back Tap 是每台 iPhone 的本地状态，请在 iPhone 上配置；Mac 不会显示虚假的跨设备授权状态。")
          .font(.caption).foregroundStyle(FiscalColor.tertiary)
        if let message = model.message { Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(FiscalColor.expense) }
      }.frame(maxWidth: 660).padding(22).frame(maxWidth: .infinity, alignment: .top)
    }.background(FiscalColor.macBackground).task { if model.phase == .idle { await model.load() } }
  }
}
#endif
