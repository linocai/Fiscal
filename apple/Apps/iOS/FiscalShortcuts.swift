import AppIntents
import FiscalKit
import Foundation

private actor FiscalIntentInputClient {
  static let shared = FiscalIntentInputClient()

  private let submission: AIInputSubmissionService
  private let ocr = VisionOCRService()
  private let photos = LatestScreenshotPhotoLibrary()

  private init() {
    let transport = APITransport(baseURL: APIConfiguration.baseURL())
    submission = AIInputSubmissionService(
      repository: RemoteAIProposalRepository(transport: transport))
  }

  func submitText(_ text: String) async throws -> AIProposalDTO {
    try await submission.submit(source: .shortcutText, text: text)
  }

  func submitImage(_ file: IntentFile?) async throws -> AIProposalDTO {
    let data =
      if let file {
        file.data
      } else {
        try await photos.latestScreenshotData(requestAccess: false)
      }
    let result = try await ocr.recognize(imageData: data)
    return try await submission.submit(source: .ocr, text: result.text)
  }
}

private struct RecordFiscalTextIntent: AppIntent {
  static let title: LocalizedStringResource = "用文本记账"
  static let description = IntentDescription("把自然语言记账内容发送给 Fiscal；安全条件不足时会进入待确认队列。")
  static let supportedModes: IntentModes = .background

  @Parameter(
    title: "记账内容",
    description: "例如：今天午餐 28 元，用招行储蓄卡，分类餐饮"
  )
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("用 Fiscal 记录 \(\.$text)") {}
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    do {
      let proposal = try await FiscalIntentInputClient.shared.submitText(text)
      await FiscalNotificationService.notify(for: proposal)
      return .result(dialog: IntentDialog(stringLiteral: AIInputFeedback.success(for: proposal)))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .result(dialog: IntentDialog(stringLiteral: AIInputFeedback.message(for: error)))
    }
  }
}

private struct RecordFiscalScreenshotIntent: AppIntent {
  static let title: LocalizedStringResource = "用截图记账"
  static let description = IntentDescription("识别传入图片；未传图片时读取照片中最新的可访问截图。图片仅在设备端识别，不会上传。")
  static let supportedModes: IntentModes = .background

  @Parameter(title: "截图", description: "可选；留空时读取照片中最新截图")
  var image: IntentFile?

  static var parameterSummary: some ParameterSummary {
    Summary("用 Fiscal 识别截图 \(\.$image)") {}
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    do {
      let proposal = try await FiscalIntentInputClient.shared.submitImage(image)
      await FiscalNotificationService.notify(for: proposal)
      return .result(dialog: IntentDialog(stringLiteral: AIInputFeedback.success(for: proposal)))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .result(dialog: IntentDialog(stringLiteral: AIInputFeedback.message(for: error)))
    }
  }
}

struct FiscalAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RecordFiscalTextIntent(),
      phrases: ["用 \(.applicationName) 记账", "让 \(.applicationName) 记录一笔"],
      shortTitle: "文本记账",
      systemImageName: "text.badge.plus")
    AppShortcut(
      intent: RecordFiscalScreenshotIntent(),
      phrases: ["用 \(.applicationName) 识别截图", "让 \(.applicationName) 截图记账"],
      shortTitle: "截图记账",
      systemImageName: "text.viewfinder")
  }

  static let shortcutTileColor: ShortcutTileColor = .navy
}
