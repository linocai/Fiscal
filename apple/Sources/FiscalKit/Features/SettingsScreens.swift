import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
  import UIKit
#endif

public struct TransactionCSVDocument: FileDocument {
  public static var readableContentTypes: [UTType] { [.commaSeparatedText] }
  private let data: Data

  public init(data: Data) { self.data = data }

  public init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

#if os(iOS)
public struct IOSSettingsScreen: View {
  @Bindable var model: AISettingsModel
  @Bindable var preferences: RecordingPreferences
  let accounts: AccountsModel
  let transactions: TransactionsModel
  let cache: HTTPResponseCache
  let openCategories: () -> Void
  let openReports: () -> Void
  @State private var capture = CaptureAuthorizationModel()
  @State private var accountOptions: [AccountDTO] = []
  @State private var localStatus: HTTPResponseCacheSnapshot?
  @State private var localMessage: String?
  @State private var csvDocument: TransactionCSVDocument?
  @State private var showCSVExporter = false
  @State private var isExportingCSV = false
  @Environment(\.openURL) private var openURL
  public init(
    model: AISettingsModel,
    preferences: RecordingPreferences,
    accounts: AccountsModel,
    transactions: TransactionsModel,
    cache: HTTPResponseCache = .shared,
    openCategories: @escaping () -> Void = {},
    openReports: @escaping () -> Void = {}
  ) {
    self.model = model; self.preferences = preferences; self.accounts = accounts
    self.transactions = transactions; self.cache = cache
    self.openCategories = openCategories; self.openReports = openReports
  }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        settingsNotice
        section("记账偏好") { recordingPreferencesCard }
        section("快捷录入") {
          VStack(spacing: 12) {
            CaptureSourceSettingsCard(model: model, compact: true)
            DeviceCaptureSettingsCard(model: capture, openSystemSettings: openSystemSettings)
          }
        }
        section("AI 自动记账") { AISettingsCard(model: model, compact: true) }
        section("分类与统计") { classificationCard }
        section("数据与缓存") { dataCard }
        section("账户与同步") { p11BoundaryCard }
      }.padding(16)
    }.background(FiscalColor.iOSBackground).navigationTitle("设置")
      .task { if model.phase == .idle { await model.load() } }
      .task { await capture.refresh() }
      .task { await loadLocalState() }
      .fileExporter(
        isPresented: $showCSVExporter,
        document: csvDocument,
        contentType: .commaSeparatedText,
        defaultFilename: exportFilename
      ) { result in
        if case .failure(let error) = result { localMessage = error.localizedDescription }
        csvDocument = nil
      }
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
  private var recordingPreferencesCard: some View {
    FiscalCard(radius: 18) {
      VStack(spacing: 14) {
        settingRow("默认账户", detail: "只用于新建手工流水") {
          Picker("默认账户", selection: defaultAccountBinding) {
            Text("不预选").tag(Optional<UUID>.none)
            ForEach(accountOptions) { Text($0.name).tag(Optional($0.id)) }
          }.labelsHidden()
        }
        Divider().opacity(0.35)
        VStack(alignment: .leading, spacing: 9) {
          Text("默认类型").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
          Picker("默认类型", selection: $preferences.defaultKind) {
            ForEach(RecordingDefaultKind.allCases) { Text($0.title).tag($0) }
          }.pickerStyle(.segmented)
        }
        Divider().opacity(0.35)
        Toggle(isOn: $preferences.stayAfterSave) {
          VStack(alignment: .leading, spacing: 3) {
            Text("保存后停留在记一笔").font(.subheadline.weight(.semibold))
            Text("连续记账时清空内容并生成新的提交标识").font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
        }.toggleStyle(FiscalSwitchToggleStyle())
      }
    }.accessibilityIdentifier("settings.recordingPreferences")
  }

  private var classificationCard: some View {
    FiscalCard(radius: 18) {
      VStack(spacing: 0) {
        Button(action: openCategories) {
          infoRow("管理分类", detail: "名称、层级与 AI 识别资料", symbol: "tag", showsChevron: true)
        }.buttonStyle(.plain)
        Divider().padding(.leading, 48).opacity(0.35)
        Button(action: openReports) {
          infoRow("统计口径", detail: "消费 · 现金流 · 负债", symbol: "list.bullet.rectangle", showsChevron: true)
        }.buttonStyle(.plain)
      }
    }
  }

  private var dataCard: some View {
    FiscalCard(radius: 18) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          FiscalIconTile("square.and.arrow.up", color: FiscalColor.accent)
          VStack(alignment: .leading, spacing: 3) {
            Text("导出当前流水 CSV").font(.subheadline.weight(.semibold))
            Text("使用流水页当前搜索与高级筛选，由服务器生成规范数据")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          Spacer()
          Button(isExportingCSV ? "准备中…" : "导出") { Task { await exportCSV() } }
            .font(.caption.weight(.semibold)).buttonStyle(.plain)
            .foregroundStyle(FiscalColor.accent).disabled(isExportingCSV)
        }
        Divider().opacity(0.35)
        HStack(spacing: 12) {
          FiscalIconTile("externaldrive", color: FiscalColor.reimbursement)
          VStack(alignment: .leading, spacing: 3) {
            Text("本地只读缓存").font(.subheadline.weight(.semibold))
            Text(cacheDetail).font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          Spacer()
          Button("清除") { Task { await clearCache() } }
            .font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(FiscalColor.accent)
            .disabled(localStatus?.entryCount == 0)
        }
        if let localMessage { Text(localMessage).font(.caption).foregroundStyle(FiscalColor.secondary) }
      }
    }
  }

  private var p11BoundaryCard: some View {
    FiscalCard(radius: 18) {
      HStack(alignment: .top, spacing: 12) {
        FiscalIconTile("server.rack", color: FiscalColor.accent)
        VStack(alignment: .leading, spacing: 4) {
          Text("个人 VPS · 云端优先").font(.subheadline.weight(.semibold))
          Text("设备密钥管理与备份状态将在后续安全版本接通；当前不会显示尚未生效的退出或加密开关。")
            .font(.caption).foregroundStyle(FiscalColor.tertiary).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var defaultAccountBinding: Binding<UUID?> {
    Binding(get: { preferences.defaultAccountID }, set: { preferences.setDefaultAccount($0) })
  }
  private var cacheDetail: String {
    guard let localStatus else { return "正在读取真实状态…" }
    return localStatus.entryCount == 0
      ? "当前没有缓存响应"
      : "\(localStatus.entryCount) 个短时响应 · \(ByteCountFormatter.string(fromByteCount: Int64(localStatus.byteCount), countStyle: .memory))\(cacheAge(localStatus.lastUpdatedAt))"
  }
  private func settingRow<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12) { VStack(alignment: .leading, spacing: 3) { Text(title).font(.subheadline.weight(.semibold)); Text(detail).font(.caption).foregroundStyle(FiscalColor.tertiary) }; Spacer(); content() }
  }
  private func infoRow(_ title: String, detail: String, symbol: String, showsChevron: Bool = false) -> some View {
    HStack(spacing: 12) {
      FiscalIconTile(symbol, color: FiscalColor.accent)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(FiscalColor.tertiary)
      }
      Spacer()
      if showsChevron {
        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(FiscalColor.tertiary)
          .accessibilityHidden(true)
      }
    }.frame(minHeight: 54)
  }
  private func loadLocalState() async {
    do {
      let loaded = try await accounts.transactionOptions()
      accountOptions = loaded.filter { $0.archivedAt == nil && ($0.kind == .cash || $0.kind == .debit) }
      _ = preferences.validatedDefaultAccount(in: loaded)
    } catch { localMessage = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription }
    localStatus = await cache.snapshot()
  }
  private func clearCache() async {
    let removed = (await cache.snapshot()).entryCount
    await cache.removeAll()
    localStatus = await cache.snapshot()
    localMessage = removed == 0 ? "没有可清除的缓存" : "已清除 \(removed) 个只读响应"
  }
  private func exportCSV() async {
    guard !isExportingCSV else { return }
    isExportingCSV = true; defer { isExportingCSV = false }
    do {
      csvDocument = TransactionCSVDocument(data: try await transactions.exportCSV())
      localMessage = "CSV 已由服务器生成，选择位置完成导出"
      showCSVExporter = true
    } catch {
      localMessage = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription
    }
  }
  private var exportFilename: String {
    "Fiscal-流水-\(String(Date.now.ISO8601Format().prefix(10)))"
  }
  private func cacheAge(_ date: Date?) -> String {
    guard let date else { return "" }
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    return " · \(seconds) 秒前更新"
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
  @Bindable var preferences: RecordingPreferences
  let accounts: AccountsModel
  let cache: HTTPResponseCache
  let transactions: TransactionsModel
  let openCategories: () -> Void
  let openReports: () -> Void
  @State private var accountOptions: [AccountDTO] = []
  @State private var cacheStatus: HTTPResponseCacheSnapshot?
  @State private var localMessage: String?
  @State private var csvDocument: TransactionCSVDocument?
  @State private var showCSVExporter = false
  @State private var isExportingCSV = false

  public init(
    model: AISettingsModel,
    preferences: RecordingPreferences,
    accounts: AccountsModel,
    transactions: TransactionsModel,
    cache: HTTPResponseCache = .shared,
    openCategories: @escaping () -> Void = {},
    openReports: @escaping () -> Void = {}
  ) {
    self.model = model; self.preferences = preferences; self.accounts = accounts
    self.transactions = transactions; self.cache = cache
    self.openCategories = openCategories; self.openReports = openReports
  }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          Text("设置").font(.system(size: 23, weight: .bold))
          Spacer()
          if let settings = model.settings {
            Text("安全规则更新于 \(settings.updatedAt.formatted(date: .abbreviated, time: .shortened))")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
        }
        settingsSection("记账偏好") { recordingPreferencesCard }
        settingsSection("AI 自动记账") { AISettingsCard(model: model) }
        settingsSection("快捷录入来源") {
          VStack(alignment: .leading, spacing: 9) {
            CaptureSourceSettingsCard(model: model)
            Text("照片权限、通知与 Back Tap 是每台 iPhone 的本地状态，请在 iPhone 上配置；Mac 不会显示虚假的跨设备授权状态。")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
        }
        settingsSection("分类与统计") { classificationCard }
        settingsSection("数据与缓存") { dataCard }
        settingsSection("账户与同步") { p11BoundaryCard }
        if let message = model.message ?? localMessage {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(FiscalColor.expense)
        }
      }.frame(maxWidth: 760).padding(22).frame(maxWidth: .infinity, alignment: .top)
    }
    .background(FiscalColor.macBackground)
    .task { if model.phase == .idle { await model.load() }; await loadLocalState() }
    .fileExporter(
      isPresented: $showCSVExporter,
      document: csvDocument,
      contentType: .commaSeparatedText,
      defaultFilename: exportFilename
    ) { result in
      if case .failure(let error) = result { localMessage = error.localizedDescription }
      csvDocument = nil
    }
  }

  private func settingsSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline).padding(.horizontal, 2)
      content()
    }
  }

  private var recordingPreferencesCard: some View {
    FiscalCard(radius: 15) {
      VStack(spacing: 14) {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 3) {
            Text("默认账户").font(.subheadline.weight(.semibold))
            Text("只用于新建手工流水").font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          Spacer()
          Picker("默认账户", selection: defaultAccountBinding) {
            Text("不预选").tag(Optional<UUID>.none)
            ForEach(accountOptions) { Text($0.name).tag(Optional($0.id)) }
          }.labelsHidden().frame(width: 220)
        }
        Divider().opacity(0.35)
        HStack(spacing: 16) {
          Text("默认类型").font(.subheadline.weight(.semibold))
          Spacer()
          Picker("默认类型", selection: $preferences.defaultKind) {
            ForEach(RecordingDefaultKind.allCases) { Text($0.title).tag($0) }
          }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
        }
        Divider().opacity(0.35)
        Toggle(isOn: $preferences.stayAfterSave) {
          VStack(alignment: .leading, spacing: 3) {
            Text("保存后停留在记一笔").font(.subheadline.weight(.semibold))
            Text("成功后清空内容并轮换提交标识，编辑现有流水时不生效")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
        }.toggleStyle(FiscalSwitchToggleStyle())
      }
    }.accessibilityIdentifier("mac.settings.recordingPreferences")
  }

  private var classificationCard: some View {
    FiscalCard(radius: 15) {
      VStack(spacing: 0) {
        Button(action: openCategories) {
          macInfoRow("管理分类", detail: "名称、层级、归档与 AI 识别资料", symbol: "tag")
        }.buttonStyle(.plain)
        Divider().padding(.leading, 46).opacity(0.35)
        Button(action: openReports) {
          macInfoRow("统计口径", detail: "消费、现金流与负债的服务端口径", symbol: "chart.bar")
        }.buttonStyle(.plain)
      }
    }
  }

  private var dataCard: some View {
    FiscalCard(radius: 15) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          FiscalIconTile("square.and.arrow.up", color: FiscalColor.accent)
          VStack(alignment: .leading, spacing: 3) {
            Text("导出当前流水 CSV").font(.subheadline.weight(.semibold))
            Text("复用流水工作台当前搜索与高级筛选；由个人 VPS 生成")
              .font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          Spacer()
          Button(isExportingCSV ? "准备中…" : "导出 CSV") { Task { await exportCSV() } }
            .buttonStyle(FiscalActionButtonStyle(.secondary)).disabled(isExportingCSV)
        }
        Divider().opacity(0.35)
        HStack(spacing: 12) {
          FiscalIconTile("externaldrive", color: FiscalColor.reimbursement)
          VStack(alignment: .leading, spacing: 3) {
            Text("本地只读缓存").font(.subheadline.weight(.semibold))
            Text(cacheDetail).font(.caption).foregroundStyle(FiscalColor.tertiary)
          }
          Spacer()
          Button("清除缓存") { Task { await clearCache() } }
            .buttonStyle(FiscalActionButtonStyle(.secondary))
            .disabled(cacheStatus?.entryCount == 0)
        }
      }
    }
  }

  private var p11BoundaryCard: some View {
    FiscalCard(radius: 15) {
      HStack(alignment: .top, spacing: 12) {
        FiscalIconTile("server.rack", color: FiscalColor.accent)
        VStack(alignment: .leading, spacing: 4) {
          Text("个人 VPS · 云端优先").font(.subheadline.weight(.semibold))
          Text("设备密钥签发、轮换、撤销和备份状态将在后续安全版本接通。当前不提供尚未生效的退出、备份或加密开关。")
            .font(.caption).foregroundStyle(FiscalColor.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func macInfoRow(_ title: String, detail: String, symbol: String) -> some View {
    HStack(spacing: 12) {
      FiscalIconTile(symbol, color: FiscalColor.accent)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(FiscalColor.tertiary)
      }
      Spacer()
      Image(systemName: "chevron.right").font(.caption.bold())
        .foregroundStyle(FiscalColor.tertiary).accessibilityHidden(true)
    }.frame(minHeight: 54).contentShape(.rect)
  }

  private var defaultAccountBinding: Binding<UUID?> {
    Binding(get: { preferences.defaultAccountID }, set: { preferences.setDefaultAccount($0) })
  }
  private var cacheDetail: String {
    guard let cacheStatus else { return "正在读取真实状态…" }
    guard cacheStatus.entryCount > 0 else { return "当前没有缓存响应" }
    return "\(cacheStatus.entryCount) 个短时响应 · \(ByteCountFormatter.string(fromByteCount: Int64(cacheStatus.byteCount), countStyle: .memory))"
  }
  private func loadLocalState() async {
    do {
      let loaded = try await accounts.transactionOptions()
      accountOptions = loaded.filter {
        $0.archivedAt == nil && ($0.kind == .cash || $0.kind == .debit)
      }
      _ = preferences.validatedDefaultAccount(in: loaded)
    } catch {
      localMessage = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription
    }
    cacheStatus = await cache.snapshot()
  }
  private func clearCache() async {
    let removed = (await cache.snapshot()).entryCount
    await cache.removeAll(); cacheStatus = await cache.snapshot()
    localMessage = removed == 0 ? "没有可清除的缓存" : "已清除 \(removed) 个只读响应"
  }
  private func exportCSV() async {
    guard !isExportingCSV else { return }
    isExportingCSV = true; defer { isExportingCSV = false }
    do {
      csvDocument = TransactionCSVDocument(data: try await transactions.exportCSV())
      localMessage = "CSV 已由服务器生成，选择位置完成导出"
      showCSVExporter = true
    } catch {
      localMessage = (error as? FiscalAPIError)?.displayMessage ?? error.localizedDescription
    }
  }
  private var exportFilename: String {
    "Fiscal-流水-\(String(Date.now.ISO8601Format().prefix(10)))"
  }
}
#endif
