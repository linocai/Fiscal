#if os(iOS)
  import Foundation
  import Observation
  import Photos
  @preconcurrency import UserNotifications

  @MainActor
  @Observable
  public final class CaptureAuthorizationModel {
    public private(set) var photosStatus: PHAuthorizationStatus = .notDetermined
    public private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    public private(set) var notificationAlertsEnabled = false
    public private(set) var isRefreshing = false

    public init() {}

    public var photosTitle: String {
      switch photosStatus {
      case .notDetermined: "尚未请求"
      case .restricted: "设备已限制"
      case .denied: "已拒绝"
      case .authorized: "已允许全部照片"
      case .limited: "仅允许选中的照片"
      @unknown default: "状态未知"
      }
    }

    public var notificationTitle: String {
      switch notificationStatus {
      case .notDetermined: "尚未请求"
      case .denied: "已关闭"
      case .authorized: notificationAlertsEnabled ? "已允许提醒" : "仅部分允许"
      case .provisional: "临时安静通知"
      case .ephemeral: "临时授权"
      @unknown default: "状态未知"
      }
    }

    public var canRequestPhotos: Bool { photosStatus == .notDetermined }
    public var canRequestNotifications: Bool { notificationStatus == .notDetermined }
    public var needsSystemSettings: Bool {
      photosStatus == .denied || photosStatus == .restricted || notificationStatus == .denied
    }

    public func refresh() async {
      guard !isRefreshing else { return }
      isRefreshing = true
      defer { isRefreshing = false }
      photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      notificationStatus = settings.authorizationStatus
      notificationAlertsEnabled = settings.alertSetting == .enabled
    }

    public func requestPhotos() async {
      guard canRequestPhotos else { await refresh(); return }
      _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      await refresh()
    }

    public func requestNotifications() async {
      guard canRequestNotifications else { await refresh(); return }
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound])
      await refresh()
    }
  }
#endif
