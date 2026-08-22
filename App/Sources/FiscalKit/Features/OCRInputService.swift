import Foundation
import Vision

#if os(iOS)
  import Photos
#endif

public struct OCRTextResult: Sendable, Equatable {
  public let text: String
  public let lineCount: Int

  public init(text: String, lineCount: Int) {
    self.text = text
    self.lineCount = lineCount
  }
}

public struct VisionOCRService: Sendable {
  public init() {}

  public func recognize(imageData: Data) async throws -> OCRTextResult {
    guard !imageData.isEmpty else { throw OCRInputError.invalidImage }
    var request = RecognizeTextRequest(.revision3)
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = [
      Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US"),
    ]
    request.usesLanguageCorrection = true

    do {
      let observations = try await request.perform(on: imageData)
      let lines = Self.readingOrder(observations).compactMap { $0.topCandidates(1).first?.string }
      return try Self.result(lines: lines)
    } catch let error as OCRInputError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw OCRInputError.recognitionFailed
    }
  }

  /// Reading order via deterministic row clustering. A direct tolerance comparator
  /// (`abs(Δy) > 0.02`) is not transitive, so `sorted(by:)` would be undefined (and can trap in
  /// debug) on dense small text; group observations into rows against each row's top anchor and
  /// sort within a row left-to-right instead (L2).
  static func readingOrder(_ observations: [RecognizedTextObservation]) -> [RecognizedTextObservation] {
    let tolerance = 0.02
    let topDown = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
    var rows: [[RecognizedTextObservation]] = []
    for observation in topDown {
      if let anchor = rows.last?.first?.boundingBox.origin.y,
        anchor - observation.boundingBox.origin.y <= tolerance {
        rows[rows.count - 1].append(observation)
      } else {
        rows.append([observation])
      }
    }
    return rows.flatMap { $0.sorted { $0.boundingBox.origin.x < $1.boundingBox.origin.x } }
  }

  public static func result(lines: [String]) throws -> OCRTextResult {
    let text = AIInputSubmissionService.normalized(lines.joined(separator: "\n"))
    guard !text.isEmpty else { throw OCRInputError.noText }
    guard text.count <= 2_000 else { throw OCRInputError.textTooLong }
    return OCRTextResult(text: text, lineCount: text.split(separator: "\n").count)
  }
}

public enum OCRInputError: Error, LocalizedError, Sendable, Equatable {
  case photoAccessNotDetermined
  case photoAccessDenied
  case photoAccessRestricted
  case noScreenshot
  case screenshotTooOld
  case screenshotUnavailable
  case invalidImage
  case noText
  case textTooLong
  case recognitionFailed

  public var errorDescription: String? {
    switch self {
    case .photoAccessNotDetermined: "请先打开 Fiscal 设置，授权照片访问后再读取最新截图。"
    case .photoAccessDenied: "Fiscal 没有照片读取权限，请在系统设置中允许访问照片。"
    case .photoAccessRestricted: "当前设备限制了照片访问，无法读取最新截图。"
    case .noScreenshot: "可访问的照片中没有截图；若使用受限访问，请先把目标截图加入允许列表。"
    case .screenshotTooOld: "最新截图已超过 10 分钟，请重新截屏后再运行快捷指令。"
    case .screenshotUnavailable: "最新截图暂时无法读取，请确认它已从 iCloud 下载。"
    case .invalidImage: "传入的图片无法读取。"
    case .noText: "截图中没有识别到文字。"
    case .textTooLong: "截图文字过多，请裁剪后重试。"
    case .recognitionFailed: "截图文字识别失败，请换一张更清晰的图片。"
    }
  }
}

#if os(iOS)
  public struct LatestScreenshotPhotoLibrary: Sendable {
    public init() {}

    public func authorizationStatus() -> PHAuthorizationStatus {
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestAccessIfNeeded() async -> PHAuthorizationStatus {
      let status = authorizationStatus()
      guard status == .notDetermined else { return status }
      return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public func latestScreenshotData(requestAccess: Bool = true) async throws -> Data {
      let status = requestAccess ? await requestAccessIfNeeded() : authorizationStatus()
      switch status {
      case .authorized, .limited: break
      case .denied: throw OCRInputError.photoAccessDenied
      case .restricted: throw OCRInputError.photoAccessRestricted
      case .notDetermined: throw OCRInputError.photoAccessNotDetermined
      @unknown default: throw OCRInputError.photoAccessDenied
      }

      let options = PHFetchOptions()
      options.fetchLimit = 1
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      options.predicate = NSPredicate(
        format: "mediaType == %d AND (mediaSubtype & %d) != 0",
        PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue)
      guard let asset = PHAsset.fetchAssets(with: options).firstObject else {
        throw OCRInputError.noScreenshot
      }
      guard let createdAt = asset.creationDate,
        Date().timeIntervalSince(createdAt) <= 10 * 60
      else { throw OCRInputError.screenshotTooOld }

      let imageOptions = PHImageRequestOptions()
      imageOptions.deliveryMode = .highQualityFormat
      imageOptions.version = .current
      imageOptions.isNetworkAccessAllowed = true
      return try await withCheckedThrowingContinuation { continuation in
        PHImageManager.default().requestImageDataAndOrientation(
          for: asset, options: imageOptions
        ) { data, _, _, info in
          if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
            continuation.resume(throwing: CancellationError())
          } else if let data {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: OCRInputError.screenshotUnavailable)
          }
        }
      }
    }
  }
#endif
