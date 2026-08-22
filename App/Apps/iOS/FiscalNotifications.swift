import FiscalKit
import UIKit
@preconcurrency import UserNotifications

enum FiscalNotificationContract {
    static let executedCategory = "FISCAL_AI_EXECUTED"
    static let pendingCategory = "FISCAL_AI_PENDING"
    static let resultCategory = "FISCAL_AI_RESULT"
    static let undoAction = "FISCAL_AI_UNDO"
    static let proposalID = "proposal_id"
    static let proposalVersion = "proposal_version"
    static let transactionID = "transaction_id"
    static let transactionVersion = "transaction_version"

    static func register() {
        let undo = UNNotificationAction(
            identifier: undoAction,
            title: "撤销这笔记账",
            options: [.authenticationRequired]
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: executedCategory,
                actions: [undo],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: pendingCategory,
                actions: [],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: resultCategory,
                actions: [],
                intentIdentifiers: []
            ),
        ])
    }
}

enum FiscalNotificationService {
    static func notify(for proposal: AIProposalDTO) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        else { return }

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = "fiscal-ai"
        switch proposal.status {
        case .executed:
            guard let transactionID = proposal.transactionID,
                let transactionVersion = proposal.transactionVersion
            else { return }
            content.title = "Fiscal 已自动记账"
            content.body = "点按查看，或验证身份后从通知撤销。"
            content.categoryIdentifier = FiscalNotificationContract.executedCategory
            content.userInfo = [
                FiscalNotificationContract.proposalID: proposal.id.uuidString,
                FiscalNotificationContract.proposalVersion: proposal.version,
                FiscalNotificationContract.transactionID: transactionID.uuidString,
                FiscalNotificationContract.transactionVersion: transactionVersion,
            ]
        case .pending:
            content.title = "Fiscal 需要你确认"
            content.body = "识别结果已进入 AI 待确认。"
            content.categoryIdentifier = FiscalNotificationContract.pendingCategory
            content.userInfo = [FiscalNotificationContract.proposalID: proposal.id.uuidString]
        default:
            return
        }
        let identifier = "ai-proposal-\(proposal.id.uuidString.lowercased())"
        try? await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }

    static func handleUndo(userInfo: [AnyHashable: Any]) async {
        guard
            let proposalRaw = userInfo[FiscalNotificationContract.proposalID] as? String,
            let proposalID = UUID(uuidString: proposalRaw),
            let transactionRaw = userInfo[FiscalNotificationContract.transactionID] as? String,
            UUID(uuidString: transactionRaw) != nil,
            let proposalVersion = integer(
                userInfo[FiscalNotificationContract.proposalVersion]),
            let transactionVersion = integer(
                userInfo[FiscalNotificationContract.transactionVersion])
        else {
            await postResult("无法读取撤销凭据，请打开 Fiscal 处理。")
            return
        }

        let repository = RemoteAIProposalRepository(
            transport: APITransport(baseURL: APIConfiguration.baseURL())
        )
        do {
            _ = try await repository.undo(
                id: proposalID,
                expectedVersion: proposalVersion,
                expectedTransactionVersion: transactionVersion
            )
            let identifier = "ai-proposal-\(proposalID.uuidString.lowercased())"
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            await postResult("这笔 AI 记账已安全撤销。")
        } catch let error as FiscalAPIError where error.code == "ai_undo_transaction_changed" {
            await postResult("流水后来已被修改，旧通知不能撤销；请打开 Fiscal 处理。")
        } catch {
            await postResult("撤销没有完成，请打开 Fiscal 检查后重试。")
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func postResult(_ message: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Fiscal"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = FiscalNotificationContract.resultCategory
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "ai-undo-result",
            content: content,
            trigger: nil
        ))
    }
}

final class FiscalAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        FiscalNotificationContract.register()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == FiscalNotificationContract.undoAction else { return }
        await FiscalNotificationService.handleUndo(
            userInfo: response.notification.request.content.userInfo
        )
    }
}
