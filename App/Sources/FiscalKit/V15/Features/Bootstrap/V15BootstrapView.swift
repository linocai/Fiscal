import SwiftUI

public struct V15BootstrapView: View {
    @State private var passphrase = ""
    @State private var showsPassphrase = false
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
        ZStack {
            V15Palette.paper.color.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 28)
                VStack(spacing: 15) {
                    Text("F")
                        .font(.largeTitle.bold())
                        .foregroundStyle(V15Palette.teal.color)
                        .frame(width: 88, height: 88)
                        .background(V15Palette.yellow.color, in: RoundedRectangle(cornerRadius: 20))
                    Text("Fiscal").font(V15Typography.surfaceTitle)
                    Text("输入个人口令以解锁本机账本")
                        .font(V15Typography.secondary)
                        .foregroundStyle(V15Palette.ink.color.opacity(0.58))
                    content
                }
                .frame(maxWidth: 390)
                Spacer(minLength: 28)
                serviceFootnote
            }
            .padding(28)
        }
        .task {
            await model.connect()
            releaseShellIfAvailable()
        }
        .accessibilityIdentifier("v15.f1a.bootstrap")
    }
    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            V15LoadingSkeleton(layout: .compact).padding(.top, 18).accessibilityIdentifier("v15.f1a.connecting")
        case .needsPassphrase, .wrongPassphrase, .invalidAccessKey, .credentialGenerationChanged:
            VStack(alignment: .leading, spacing: 12) {
                if case .invalidAccessKey = model.phase {
                    Label("本机登录信息无效", systemImage: "key.slash")
                        .font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
                    Text("请重新输入个人访问口令解锁本机。")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
                if case .credentialGenerationChanged = model.phase {
                    Label("口令修改后需要重新解锁", systemImage: "key.slash")
                        .font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
                    Text("个人访问口令已经修改，请用新口令重新解锁本机。")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Group {
                        if showsPassphrase { TextField("个人访问口令", text: $passphrase) }
                        else { SecureField("个人访问口令", text: $passphrase) }
                    }
                    .textFieldStyle(.plain)
                    .font(V15Typography.body)
                    .onSubmit { unlock() }
                    Button(showsPassphrase ? "隐藏" : "显示") { showsPassphrase.toggle() }
                        .buttonStyle(.plain).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.62))
                }
                .padding(.horizontal, 14).frame(minHeight: 54)
                .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(V15Palette.teal.color, lineWidth: 1) }
                if case .wrongPassphrase = model.phase {
                    Label("口令不正确，请重新输入。", systemImage: "exclamationmark.circle")
                        .font(V15Typography.secondary).foregroundStyle(V15Palette.teal.color)
                }
                V15ActionButton("解锁", action: unlock)
                V15ActionButton("修改口令", kind: .quiet, disabledReason: .init(code: "authenticated_session_required", message: "修改口令需要有效会话；请先解锁，再到“系统与数据”中修改。", fieldPath: nil)) {}
            }
            .padding(.top, 20)
        case .passphraseNotSet: compactState(title: "尚未设置访问口令", message: "请先完成个人访问口令设置。", retry: false)
        case .systemNotReady: compactState(title: "系统尚未就绪", message: "系统正在启动；请稍后重试。", retry: true)
        case .ready: V15LoadingSkeleton(layout: .compact).accessibilityIdentifier("v15.f1a.opening")
        case .offlineReadOnly(let at):
            VStack(alignment: .leading, spacing: V15Spacing.sm) {
                V15OfflineReadOnlyBanner(snapshotAt: at)
                Text("设备当前离线，只能查看上次保存的数据；系统和安全设置不会在离线时提交。")
                    .font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
                V15ActionButton("查看上次数据", symbol: "clock.arrow.circlepath") { onAvailable() }
                V15ActionButton("重试连接", symbol: V15Symbol.retry, kind: .secondary) { Task { await model.retry(); releaseShellIfAvailable() } }
            }
            .padding(.top, 18)
        case .failed(let message): compactState(title: "无法连接", message: message, retry: true)
        }
    }

    private var serviceFootnote: some View {
        HStack(spacing: 9) {
            Circle().fill(footnoteColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(footnoteTitle).font(V15Typography.secondary.weight(.semibold))
                Text(serviceVersionLine).font(V15Typography.label.monospacedDigit()).foregroundStyle(V15Palette.ink.color.opacity(0.52))
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 58)
        .background(V15Palette.paper.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(V15Palette.hairline.color) }
        .frame(maxWidth: 390)
    }

    private var footnoteColor: Color {
        switch model.phase { case .failed(_), .systemNotReady, .invalidAccessKey, .credentialGenerationChanged: V15Palette.yellow.color; default: V15Palette.teal.color }
    }
    private var footnoteTitle: String {
        switch model.phase { case .failed(_): "暂时无法连接"; case .systemNotReady: "系统正在启动"; case .invalidAccessKey: "本机登录信息无效"; case .credentialGenerationChanged: "需要重新解锁"; case .offlineReadOnly(_): "可查看上次数据"; default: "连接正常" }
    }
    private var serviceVersionLine: String { "人民币 · 上海时区" }

    private func compactState(title: String, message: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(V15Typography.body.weight(.semibold)).foregroundStyle(V15Palette.teal.color)
            Text(message).font(V15Typography.secondary).foregroundStyle(V15Palette.ink.color.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            if retry { V15ActionButton("重试", symbol: V15Symbol.retry, kind: .secondary) { Task { await model.retry() } } }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(V15Palette.card.color, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(V15Palette.hairline.color) }
        .padding(.top, 18)
    }

    private func unlock() {
        Task {
            await model.unlock(passphrase: passphrase)
            releaseShellIfAvailable()
        }
    }

    private func releaseShellIfAvailable() {
        switch model.phase {
        case .ready:
            onAvailable()
        default:
            break
        }
    }
}
