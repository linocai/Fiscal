import SwiftUI

public struct V15BootstrapView: View {
    @State private var passphrase = ""
    @State private var model: V15BootstrapModel
    private let onAvailable: @MainActor () -> Void

    /// The formal V15 shell owns navigation.  Bootstrap remains responsible
    /// for the real auth/system reads and only releases that shell after a
    /// server-ready or offline-read-only outcome.
    public init(services: V15Services, onAvailable: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: .init(services: services))
        self.onAvailable = onAvailable
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: V15Spacing.lg) {
            Text("连接 Fiscal").font(V15Typography.surfaceTitle)
            Text("只连接你的个人账簿。不会创建离线写入队列。") .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66))
            content
        }
        .padding(V15Spacing.lg).background(V15Palette.paper.color)
        .task {
            await model.connect()
            releaseShellIfAvailable()
        }
        .accessibilityIdentifier("v15.f1a.bootstrap")
    }
    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading: V15LoadingSkeleton()
        case .needsPassphrase, .wrongPassphrase:
            V15Section("访问口令") {
                V15Field("口令", text: $passphrase, prompt: "输入个人访问口令")
                if case .wrongPassphrase = model.phase { Text("口令不正确，请重新输入。").foregroundStyle(V15Palette.teal.color) }
                V15ActionButton("连接", action: {
                    Task {
                        await model.unlock(passphrase: passphrase)
                        releaseShellIfAvailable()
                    }
                })
            }
        case .passphraseNotSet: V15EmptyState(title: "尚未设置访问口令", explanation: "请先在服务器完成个人访问口令设置。")
        case .systemNotReady: V15ServiceErrorState(message: "服务尚未准备好。", retry: { Task { await model.retry() } })
        case .ready: V15SuccessReceiptState(title: "已连接", detail: "服务器与账簿已准备好。")
        case .offlineReadOnly(let at): V15OfflineReadOnlyBanner(snapshotAt: at)
        case .failed(let message): V15ServiceErrorState(message: message, retry: { Task { await model.retry() } })
        }
    }

    private func releaseShellIfAvailable() {
        switch model.phase {
        case .ready, .offlineReadOnly:
            onAvailable()
        default:
            break
        }
    }
}
